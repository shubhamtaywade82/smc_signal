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
| C — Market regime detection | OptionChainAnalyzer computes `:trending / :ranging / :neutral / :expiry_gamma / :high_vix` |
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

### IV skew calculation

`iv_skew = avg_pe_iv / avg_ce_iv`, where averages are taken over ATM ± 2 strikes only (i.e. the 5 strikes closest to spot). This avoids deep-OTM outliers distorting the ratio.

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
  option_chain:   chain_hash,   # { strike => { "ce" => {...}, "pe" => {...} } }
  spot_price:     22480.0,
  adx:            28.5,
  days_to_expiry: 2             # 0 = expiry day (Thursday NIFTY, Friday SENSEX)
)
```

**Output — `chain_context` hash**:
```ruby
{
  pcr:              0.92,          # total put OI / total call OI
  max_pain:         22450,         # strike minimising aggregate writer loss (see formula)
  ce_walls:         [22500, 22600],# top-2 CE OI strikes above spot → resistance
  pe_walls:         [22300, 22200],# top-2 PE OI strikes below spot → support
  iv_skew:          1.18,          # avg PE IV / avg CE IV (ATM ± 2 strikes only)
  regime:           :trending,     # see regime table
  nearest_ce_wall:  22500,         # closest CE wall above spot; nil if none exists
  nearest_pe_wall:  22300          # closest PE wall below spot; nil if none exists
}
```

**Regime classification**:

| Tag | Condition |
|-----|-----------|
| `:trending` | ADX ≥ 25, PCR 0.70–1.30 |
| `:neutral` | ADX ≥ 20 and ADX < 25 (transition zone) |
| `:ranging` | ADX < 20 |
| `:expiry_gamma` | days_to_expiry == 0 |
| `:high_vix` | iv_skew > `high_iv_skew_threshold` (default 1.40) OR avg ATM IV > `high_iv_threshold` |

ADX in [20, 25) maps to `:neutral`, not `:ranging`. This aligns with the existing `moderate_trend_adx: 25.0` boundary in `OptionsBuyingPolicy` — ADX 22 is currently a valid trade entry and must remain so.

Regime priority when multiple conditions match: `:expiry_gamma` > `:high_vix` > `:trending` > `:neutral` > `:ranging`.

**Max Pain calculation** (correct directional writer-loss formula):
```
total_writer_loss(S) =
  Σ_K [ max(0, S - K) × ce_oi_at_K ]   # CE writers lose when spot > their strike
+ Σ_K [ max(0, K - S) × pe_oi_at_K ]   # PE writers lose when spot < their strike

Max Pain = strike S that minimises total_writer_loss(S)
```
This uses `max(0, ...)` not absolute value — CE writers are not harmed when spot is below their strike, and PE writers are not harmed when spot is above theirs.

**`nearest_ce_wall` / `nearest_pe_wall` nil handling**:
- If no CE strike with meaningful OI exists above spot → `nearest_ce_wall: nil`
- If no PE strike with meaningful OI exists below spot → `nearest_pe_wall: nil`
- Gate 2 in `OptionsBuyingPolicy` skips the check entirely when the relevant wall is nil.

---

### Modified: `lib/options_buying_policy.rb`

`recommendation` gains an optional `chain_context:` keyword argument (nil by default).

**Backward compatibility**: when `chain_context` is nil, all three new gates are bypassed entirely. The method behaves identically to the pre-change version. No partial gate logic runs.

When `chain_context` is non-nil, three new gates run after the existing ADX gate:

**Gate 1 — Regime gate**
```
:trending     → allow at normal min_trend_adx floor
:neutral      → allow at normal min_trend_adx floor (same as trending)
:expiry_gamma → allow (gamma scalp mode)
:high_vix     → allow only if ADX ≥ high_vix_min_adx (default 30.0, stricter floor)
:ranging      → no_trade("regime is ranging — avoid buying options")
```

**Gate 2 — OI wall proximity gate** (skipped if relevant wall is nil)
```
CE trade: if nearest_ce_wall present AND (nearest_ce_wall - spot) ≤ 1 × strike_step
  → no_trade("spot within 1 step of CE wall — resistance risk")
PE trade: if nearest_pe_wall present AND (spot - nearest_pe_wall) ≤ 1 × strike_step
  → no_trade("spot within 1 step of PE wall — support risk")
```
`strike_step` defaults to 50.0 (NIFTY) and is configurable.

**Gate 3 — PCR confirmation gate**
```
CE trade: if pcr < pcr_ce_floor (default 0.60) → no_trade("pcr extreme against CE trade")
PE trade: if pcr > pcr_pe_ceiling (default 1.40) → no_trade("pcr extreme against PE trade")
```

**New config keys** (all override-able via policy JSON, follow existing `min_trend_adx` naming convention):
```ruby
{
  strike_step:            50.0,
  pcr_ce_floor:           0.60,
  pcr_pe_ceiling:         1.40,
  high_vix_min_adx:       30.0,   # stricter ADX floor in :high_vix regime
  high_iv_skew_threshold: 1.40,   # iv_skew above this → :high_vix regime
  high_iv_threshold:      25.0    # avg ATM IV above this → :high_vix regime (annualised %)
}
```

---

### Modified: `lib/options_backtester.rb`

`simulate_trade` records OI walls, PCR, and max pain from `chain_context` at entry time. `find_exit` checks three new conditions before the existing SL/TP/signal_flip checks.

**PCR sampling**: PCR is captured once at entry time from the `chain_context` snapshot. There is no per-bar PCR re-fetch during the hold period in backtesting. The `pcr_reversal` exit compares PCR-at-entry to a threshold shift — it is a static gate, not a live time-series comparison. This is a deliberate simplification: per-bar historical chain data is not available from DhanHQ's expired options API in the same snapshot shape.

In live mode (`scripts/options_buy_signal.rb`), PCR at exit time can be re-evaluated if desired, but this is out of scope for this spec.

**`chain_data_provider:` injectable dependency**:
```ruby
# Call signature — returns a chain_context hash or nil
chain_data_provider.call(
  signal_time:    Time,     # timestamp of the signal bar
  security_id:    Integer,
  exchange_segment: String
)
```
Defaults to nil (no chain exits run). Injected in tests as a lambda/proc returning a synthetic `chain_context`. Production scripts pass a live fetcher.

**New exit checks (per bar, in priority order)**:

1. **max_pain_gravity** — expiry day only (days_to_expiry == 0)
   Trigger: candle close moves further toward max_pain than entry close (away from trade direction).
   Exit: at candle close. Reason: `"max_pain_gravity"`.

2. **oi_wall_target** — dynamic profit target (skipped if wall was nil at entry)
   CE trade: if candle **close** ≥ `ce_wall_at_entry` → exit at candle close.
   PE trade: if candle **close** ≤ `pe_wall_at_entry` → exit at candle close.
   Close-based (not intrabar high/low) to be consistent with signal_flip exit behaviour.
   Reason: `"oi_wall_target"`.

3. **pcr_reversal** — entry-time PCR gate
   CE trade: if `pcr_at_entry` < `pcr_ce_floor` (same threshold as entry Gate 3) — this prevents entries that slipped through on a boundary; not re-evaluated per bar. Skip if `pcr_at_entry` is nil.
   *Note*: PCR reversal is an entry-time filter masquerading as an exit check in the backtester. True per-bar PCR reversal is out of scope.
   Reason: `"pcr_reversal"`.

**Full exit priority order**:
```
1. max_pain_gravity  (expiry day only)
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
  chain_regime:       "trending",         # serialised as string (not symbol)
  pcr_at_entry:       0.92,
  ce_wall_at_entry:   22500,              # nil if no wall existed
  pe_wall_at_entry:   22300,              # nil if no wall existed
  max_pain_at_entry:  22450
}
```

**New config namespace** — chain-related config lives under `config[:chain]`:
```ruby
DEFAULT_CONFIG = {
  # ... existing risk / liquidity / expiry keys ...
  chain: {
    pcr_reversal_delta: 0.25,  # not used in backtester (static gate); reserved for future live mode
    strike_step:        50.0
  }
}.freeze
```

New CLI flags map to `config[:chain]`:
```
--pcr-reversal-delta N   → config[:chain][:pcr_reversal_delta]
--strike-step N          → config[:chain][:strike_step]
```

---

### Modified: `scripts/options_buy_signal.rb`

Add `days_to_expiry` helper (script-level private method):
```ruby
def days_to_expiry(expiry_date_string)
  return 0 if expiry_date_string.nil?
  expiry = Date.parse(expiry_date_string.to_s)
  today = Date.today
  [(expiry - today).to_i, 0].max
rescue ArgumentError
  nil
end
```
Returns 0 on expiry day, positive integer otherwise, nil on parse failure.

After fetching the option chain, instantiate `OptionChainAnalyzer`:
```ruby
chain_context = OptionChainAnalyzer.new.analyze(
  option_chain:   option_chain,
  spot_price:     latest[:close],
  adx:            latest[:adx],
  days_to_expiry: days_to_expiry(expiry)
)

policy = OptionsBuyingPolicy.new(config: policy_config).recommendation(
  signal:        latest[:signal],
  adx:           latest[:adx],
  atr_pct:       latest[:atr_pct],
  chain_context: chain_context
)
```

The JSON output payload gains `chain_context` as a top-level key alongside `instrument`, `signal_context`, `policy`, and `selected_contract`. All symbol values (`:regime`) are serialised as strings via `.to_s` before JSON serialisation.

---

### Modified: `scripts/backtest_options.rb`

Pass chain context into backtester via `chain_data_provider:` injectable. New CLI flags:
```
--pcr-reversal-delta N   PCR shift threshold (default 0.25, stored in config[:chain])
--strike-step N          Strike interval (default 50, stored in config[:chain])
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
| `scripts/options_buy_signal.rb` | Wire OptionChainAnalyzer → policy; add `days_to_expiry` helper |
| `scripts/backtest_options.rb` | New CLI flags, wire chain context |
| `spec/option_chain_analyzer_spec.rb` | **New** — unit tests |
| `spec/options_buying_components_spec.rb` | Extend for new gates |
| `spec/options_backtester_spec.rb` | Extend for new exit reasons |

---

## Testing Strategy

- `OptionChainAnalyzer`: unit tests with synthetic chain hashes — verify PCR, max pain (directional formula), wall detection, regime tagging for all five regimes including ADX [20, 25) → `:neutral`, nil wall cases
- `OptionsBuyingPolicy`: extend existing spec — test each new gate in isolation with injected `chain_context`; test nil `chain_context` preserves original behaviour exactly
- `OptionsBacktester`: inject mock `chain_data_provider` lambda; test each new exit reason fires in correct priority order; test nil provider leaves exit logic unchanged
- All new gates are opt-in (nil chain_context / nil provider = existing behaviour) so all existing specs pass unchanged

---

## Out of Scope (Future)

- Delta/Gamma targeting for strike selection (extends `LiveOptionSelector`)
- IV Rank / IVR filter (requires historical IV series — separate data fetch)
- Per-bar live PCR re-evaluation during hold period
- Opening Range Breakout strategy mode
- Contrarian PCR mean-reversion strategy mode
- Multi-timeframe regime confirmation
