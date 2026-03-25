# Option Chain Intelligence Hub — Design Spec
**Date**: 2026-03-25
**Status**: Approved
**Scope**: Entry quality (A), market regime detection (C), and exit management (D) for NIFTY/SENSEX options buying

---

## Background

The existing system generates directional signals (SuperTrend + ADX → `BUY CALLS` / `BUY PUTS`) and selects a liquid option contract, but makes no use of option chain data beyond liquidity filtering (OI, spread). This means:

- Entries fire regardless of whether IV is cheap or expensive
- No awareness of OI walls (resistance/support anchored by institutional writing)
- No regime detection — same strategy runs in trending and choppy markets
- Exits are fixed SL/TP percentages with no market-structure anchors

This spec designs the **Option Chain Intelligence Hub**: a new `OptionChainAnalyzer` class whose output feeds both the entry policy and the backtester exit logic.

---

## Goals

| Pain point | Resolution |
|------------|-----------|
| A — Entry quality | Regime gate, OI wall proximity gate, PCR confirmation gate |
| C — Market regime detection | OptionChainAnalyzer computes `:trending / :ranging / :expiry_gamma / :high_vix` |
| D — Exit management | OI wall target, PCR reversal, Max Pain gravity exits |

---

## Greek & Option Chain Concepts (Reference)

### Greeks for options buyers

| Greek | Role | Buyer wants |
|-------|------|-------------|
| Delta (Δ) | Price sensitivity to spot move | 0.35–0.50 — responsive but not over-paying |
| Gamma (Γ) | Rate of delta growth | High — accelerates profit as move continues |
| Theta (Θ) | Daily time decay cost | Low — minimise bleed while holding |
| Vega (V) | Sensitivity to IV change | Positive — want IV to expand after entry |
| IV Rank (IVR) | Where IV sits in 52-week range | < 30–40 — cheap premium, room to expand |

**Core buyer rule**: Enter when IV is LOW. Exit before theta dominates or IV collapses.

### Option chain signals

| Field | Buyer signal |
|-------|-------------|
| CE OI (high at a strike) | Resistance wall — price struggles; breaking through = explosive move |
| PE OI (high at a strike) | Support wall — price bounces or breaks violently |
| OI change direction | Rising OI + rising price = fresh long (bullish confirmation) |
| PCR (put OI / call OI) | > 1.2 = contrarian bullish; < 0.7 = contrarian bearish |
| Max Pain strike | Spot gravitates toward it near expiry — dangerous for buyers |
| IV skew (PE IV / CE IV) | > 1.4 = fear premium; elevated PE demand = bearish sentiment |

### Spot behaviour → strategy mapping

| Spot pattern | Strategy | Best timeframe |
|-------------|----------|----------------|
| Strong trend (ADX > 25) | Momentum CE/PE buy (existing) | 1–15 min |
| Spot at PE OI wall from above | Support bounce → CE buy | 5–15 min |
| Spot at CE OI wall from below | Resistance → PE buy | 5–15 min |
| OI wall break (closes beyond) | Breakout continuation | 5–15 min |
| PCR extreme reversal bar | Contrarian mean reversion | 15–60 min |
| Expiry day near ATM | Gamma scalp | 1–3 min |

---

## Architecture

### New class: `lib/option_chain_analyzer.rb`

Single responsibility: accept an option chain hash and spot price + ADX, return a `chain_context` hash.

**Input** (same format already used by `LiveOptionSelector`):
```ruby
OptionChainAnalyzer.new.analyze(
  option_chain: chain_hash,   # { strike => { "ce" => {...}, "pe" => {...} } }
  spot_price:   22480.0,
  adx:          28.5,
  days_to_expiry: 2           # 0 = expiry day
)
```

**Output — `chain_context` hash**:
```ruby
{
  pcr:              0.92,          # total put OI / total call OI
  max_pain:         22450,         # strike minimising aggregate OI loss
  ce_walls:         [22500, 22600],# top-2 CE OI strikes → resistance
  pe_walls:         [22300, 22200],# top-2 PE OI strikes → support
  iv_skew:          1.18,          # avg PE IV / avg CE IV
  regime:           :trending,     # see regime table
  nearest_ce_wall:  22500,         # closest CE wall above spot
  nearest_pe_wall:  22300          # closest PE wall below spot
}
```

**Regime classification**:

| Tag | Condition |
|-----|-----------|
| `:trending` | ADX ≥ 25, PCR 0.70–1.30 |
| `:ranging` | ADX < 20 |
| `:expiry_gamma` | days_to_expiry == 0 |
| `:high_vix` | iv_skew > 1.40 OR avg option IV above configurable threshold |

Regime priority when multiple conditions match: `:expiry_gamma` > `:high_vix` > `:trending` > `:ranging`.

**Max Pain calculation**:
For each strike S, compute: sum over all strikes K of `(|S - K| × OI at K)` for CE and PE. Max Pain = strike S minimising total loss.

---

### Modified: `lib/options_buying_policy.rb`

`recommendation` gains an optional `chain_context:` keyword argument (nil by default — fully backward compatible).

When `chain_context` is present, three new gates run after the existing ADX gate:

**Gate 1 — Regime gate**
```
:trending     → allow entry at normal ADX floor (min_trend_adx)
:expiry_gamma → allow entry (gamma scalp mode)
:high_vix     → allow entry only if ADX ≥ strong_trend_adx (stricter floor)
:ranging      → no_trade("regime is ranging — avoid buying options")
```

**Gate 2 — OI wall proximity gate**
```
CE trade: if (nearest_ce_wall - spot) ≤ 1 × strike_step → no_trade("spot within 1 step of CE wall")
PE trade: if (spot - nearest_pe_wall) ≤ 1 × strike_step → no_trade("spot within 1 step of PE wall")
```
`strike_step` defaults to 50 (NIFTY) and is configurable.

**Gate 3 — PCR confirmation gate**
```
CE trade: if pcr < pcr_ce_floor (default 0.60) → no_trade("pcr extreme against CE trade")
PE trade: if pcr > pcr_pe_ceiling (default 1.40) → no_trade("pcr extreme against PE trade")
```

**New config keys** (all override-able via policy JSON):
```ruby
{
  strike_step:     50.0,
  pcr_ce_floor:    0.60,
  pcr_pe_ceiling:  1.40,
  high_vix_adx:    30.0   # stricter ADX floor in :high_vix regime
}
```

---

### Modified: `lib/options_backtester.rb`

`simulate_trade` records OI walls and PCR from `chain_context` at entry time. `find_exit` checks three new conditions before the existing SL/TP/signal_flip checks.

**New exit checks (per bar, in priority order)**:

1. **max_pain_gravity** — expiry day only
   If days_to_expiry == 0 AND spot is moving toward max_pain (away from trade direction) → exit at candle close.

2. **oi_wall_target** — dynamic profit target
   CE trade: if spot ≥ nearest_ce_wall at entry → exit at candle close.
   PE trade: if spot ≤ nearest_pe_wall at entry → exit at candle close.

3. **pcr_reversal** — regime shift warning
   If PCR has moved > `pcr_reversal_delta` (default 0.25) against trade direction since entry → exit at candle close.

**Full exit priority order**:
```
1. max_pain_gravity  (expiry day)
2. oi_wall_target
3. pcr_reversal
4. stop_loss
5. take_profit
6. signal_flip
7. max_hold_bars
```

**New trade record fields**:
```ruby
{
  ...,                                    # existing fields
  chain_regime:       :trending,
  pcr_at_entry:       0.92,
  ce_wall_at_entry:   22500,
  pe_wall_at_entry:   22300,
  max_pain_at_entry:  22450
}
```

---

### Modified: `scripts/options_buy_signal.rb`

After fetching the option chain, instantiate `OptionChainAnalyzer` and pass `chain_context` to `OptionsBuyingPolicy#recommendation`.

```ruby
chain_context = OptionChainAnalyzer.new.analyze(
  option_chain:    option_chain,
  spot_price:      latest[:close],
  adx:             latest[:adx],
  days_to_expiry:  days_to_expiry(expiry)
)

policy = OptionsBuyingPolicy.new(config: policy_config).recommendation(
  signal:        latest[:signal],
  adx:           latest[:adx],
  atr_pct:       latest[:atr_pct],
  chain_context: chain_context
)
```

The JSON output payload gains a `chain_context:` field for inspection.

---

### Modified: `scripts/backtest_options.rb`

Pass chain context into backtester. For historical backtesting, PCR/IV/OI walls are derived from the historical option chain snapshot at signal time. A `chain_data_provider:` injectable dependency (matching the existing `option_data_provider:` pattern) allows test injection.

New CLI flags:
```
--pcr-reversal-delta N   PCR shift threshold for reversal exit (default 0.25)
--strike-step N          Strike interval for wall proximity gate (default 50)
```

---

## Data Flow

```
[DhanHQ API: option_chain]
         │
         ▼
  OptionChainAnalyzer
  .analyze(chain, spot, adx, dte)
         │
    chain_context{}
       /        \
      ▼           ▼
OptionsBuyingPolicy    OptionsBacktester
(3 new entry gates)    (3 new exit reasons)
      │                        │
  no_trade / buy_option    enriched trade record
```

---

## File Changes Summary

| File | Change |
|------|--------|
| `lib/option_chain_analyzer.rb` | **New** — full analyzer |
| `lib/options_buying_policy.rb` | Add `chain_context:` param + 3 gates |
| `lib/options_backtester.rb` | Add chain-based exits + enriched trade record |
| `scripts/options_buy_signal.rb` | Wire OptionChainAnalyzer → policy |
| `scripts/backtest_options.rb` | New CLI flags, wire chain context |
| `spec/option_chain_analyzer_spec.rb` | **New** — unit tests |
| `spec/options_buying_components_spec.rb` | Extend for new gates |
| `spec/options_backtester_spec.rb` | Extend for new exit reasons |

---

## Testing Strategy

- `OptionChainAnalyzer`: unit tests with synthetic chain hashes — verify PCR, max pain, wall detection, regime tagging
- `OptionsBuyingPolicy`: extend existing spec — test each new gate in isolation with injected `chain_context`
- `OptionsBacktester`: inject mock chain data provider; test each new exit reason fires in correct priority order
- All new gates are opt-in (nil chain_context = existing behaviour) so existing specs pass unchanged

---

## Out of Scope (Future)

- Delta/Gamma targeting for strike selection (extends `LiveOptionSelector`)
- IV Rank / IVR filter (requires historical IV series — separate data fetch)
- Opening Range Breakout strategy mode
- Contrarian PCR mean-reversion strategy mode
- Multi-timeframe regime confirmation
