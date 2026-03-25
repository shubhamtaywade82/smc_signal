# SMC Signal

Signal-generation and strategy-calibration toolkit for intraday Indian market data using the DhanHQ Ruby client.

This repository provides:

- a SuperTrend/RSI/ADX-based signal engine,
- a CLI runner for inspecting bar-by-bar signals,
- parameter search,
- walk-forward calibration with constraint filters and recommended-config export.

## Input Contract (All Scripts)

Every executable in this repo uses the same market-data input contract:

- `--exchange-segment`
- `--symbol`
- `--interval`
- `--days`

Data is always fetched from DhanHQ API through instrument lookup.  
Legacy inputs like `--source`, `--security-id`, `--instrument`, `--from`, and `--to` are not used.

## What This Repo Does

Given an instrument and interval, it:

1. Resolves the instrument through `DhanHQ::Models::Instrument`.
2. Fetches intraday bars from DhanHQ API.
3. Generates strategy signals (`BUY CALLS`, `BUY PUTS`, `BOOK ...`, `HOLD`).
4. Optionally optimizes strategy parameters over the fetched period.
5. Optionally performs walk-forward calibration to reduce overfitting risk.

---

## Data Source and Broker Path

This repo uses **DhanHQ only** for Indian-market data.

Data loading for `runner.rb`, `scripts/optimize.rb`, and `scripts/walk_forward.rb` is implemented through:

- `DhanHQ::Models::Instrument.find(exchange_segment, symbol)`
- `instrument.intraday(from_date:, to_date:, interval:)`

via local gem repo:

- default path: `~/project/trading-workspace/dhanhq-client`
- override with `DHANHQ_CLIENT_PATH`

All scripts call the same shared loader in `lib/dhan_hq_api_bars.rb`.

---

## Repository Structure

- `runner.rb` — run strategy and print per-bar output + summary
- `lib/super_trend_signal_generator.rb` — strategy logic
- `lib/strategy_optimization.rb` — reusable optimization/calibration helpers
- `lib/dhan_hq_api_bars.rb` — DhanHQ instrument resolution + bar loading
- `scripts/optimize.rb` — random parameter search with constraints
- `scripts/walk_forward.rb` — rolling train/validate calibration + JSON recommendation
- `scripts/options_buy_signal.rb` — dry-run options contract selection from latest BUY signal
- `scripts/calibrate_options_policy.rb` — builds options policy JSON from ExpiredOptionsData
- `scripts/backtest_options.rb` — full options-buying backtest with trade CSV + summary JSON
- `spec/signal_generator_spec.rb` — indicator/strategy tests

---

## Prerequisites

- Ruby (same runtime used in your workspace)
- Valid Dhan credentials in environment:
  - `DHAN_CLIENT_ID`
  - `DHAN_ACCESS_TOKEN`
- Local `dhanhq-client` repository available at:
  - `~/project/trading-workspace/dhanhq-client`
  - or set `DHANHQ_CLIENT_PATH=/custom/path/to/dhanhq-client`

Optional `.env` at repo root is auto-loaded by scripts.

---

## Strategy Signals

The engine emits:

- `BUY CALLS`
- `BUY PUTS`
- `BOOK CALL PROFITS`
- `BOOK PUT PROFITS`
- `HOLD`

Important behavior:

- Signal generation is **position-aware**.
- Exit (`BOOK ...`) signals are emitted only when a matching open side exists.
- This prevents synthetic over-reporting of exits when no position is open.

---

## Running the Strategy

### Basic summary run

```bash
ruby runner.rb \
  --exchange-segment IDX_I \
  --symbol NIFTY \
  --interval 1 \
  --days 60 \
  --summary-only
```

### Full row output (default)

```bash
ruby runner.rb \
  --exchange-segment IDX_I \
  --symbol NIFTY \
  --interval 1 \
  --days 30
```

### Useful runner flags

- `--tf-minutes N` strategy timeframe profile (default `5`)
- `--signals-only` print non-`HOLD` rows only
- `--last N` print only last `N` rows
- `--summary-only` skip row table, print summary only
- `--no-color` disable ANSI colors

---

## Options Buying (Dry Run)

Generate latest signal and map it to a live options contract suggestion (no order placement):

```bash
ruby scripts/options_buy_signal.rb \
  --exchange-segment IDX_I \
  --symbol NIFTY \
  --interval 1 \
  --days 5 \
  --tf-minutes 1
```

This script:

1. fetches underlying candles,
2. computes latest strategy signal,
3. applies options buying policy (`CALL` for `BUY CALLS`, `PUT` for `BUY PUTS`),
4. loads nearest expiry option chain,
5. selects a liquid contract by moneyness, spread, OI, and strike distance.

Output is JSON payload for execution handoff.

Use calibrated policy JSON:

```bash
ruby scripts/options_buy_signal.rb \
  --exchange-segment IDX_I \
  --symbol NIFTY \
  --interval 1 \
  --days 5 \
  --tf-minutes 1 \
  --policy-json tmp/optimization/options_policy_YYYYMMDD_HHMMSS.json
```

---

## Calibrate Options Policy (ExpiredOptionsData)

Build CE/PE moneyness preferences from expired options behavior:

```bash
ruby scripts/calibrate_options_policy.rb \
  --exchange-segment IDX_I \
  --symbol NIFTY \
  --interval 1 \
  --days 30 \
  --expiry-flag WEEK \
  --expiry-code 0
```

Outputs:

- `tmp/optimization/options_policy_<timestamp>.json`

This JSON can be passed to `scripts/options_buy_signal.rb` via `--policy-json`.

---

## Backtest Options Buying

Run full options backtest with calibrated moneyness and liquidity filters:

```bash
ruby scripts/backtest_options.rb \
  --exchange-segment IDX_I \
  --symbol NIFTY \
  --interval 1 \
  --days 20 \
  --tf-minutes 1 \
  --policy-json tmp/optimization/options_policy_YYYYMMDD_HHMMSS.json \
  --sl-pct 0.30 \
  --tp-pct 0.60 \
  --max-hold-bars 20 \
  --ignore-last-signal-bars 1 \
  --min-oi 1000 \
  --max-spread-pct 4.0 \
  --expiry-flag WEEK \
  --expiry-code 1
```

Execution model:

- entry on next option candle open after buy signal,
- exit on first of SL / TP / opposite signal flip / max-hold-bars,
- ignore last `N` signal bars (default `1`) to avoid end-of-window no-entry artifacts,
- strike rule from calibrated policy (`ATM`/`ITM`/`OTM`),
- entry gated by liquidity filters (`min_oi`, spread proxy cap).

Outputs:

- `tmp/optimization/options_trades_<timestamp>.csv`
- `tmp/optimization/options_summary_<timestamp>.json`

---

## Parameter Search

Run random search over parameter space and rank by score:

```bash
ruby scripts/optimize.rb \
  --exchange-segment IDX_I \
  --symbol NIFTY \
  --interval 1 \
  --days 90 \
  --tf-minutes 1 \
  --trials 500 \
  --top 20 \
  --min-trades 8 \
  --max-drawdown 150
```

Outputs:

- console summary of best configs
- CSV in `tmp/optimization/optimize_<timestamp>.csv`

### Constraint flags

- `--min-trades N` reject configs with too few trades
- `--max-drawdown N` reject configs with high drawdown

---

## Walk-Forward Calibration

Run rolling train/validate folds:

```bash
ruby scripts/walk_forward.rb \
  --exchange-segment IDX_I \
  --symbol NIFTY \
  --interval 1 \
  --days 120 \
  --tf-minutes 1 \
  --trials 300 \
  --train-days 20 \
  --validate-days 5 \
  --top-n 10 \
  --min-trades 8 \
  --max-drawdown 150
```

What it does:

1. Builds rolling folds from fetched bars.
2. Searches params on each train fold.
3. Revalidates top `N` train configs on validate fold.
4. Selects fold winner by validation score.
5. Picks stable params by most frequent fold winner.

Outputs:

- fold CSV: `tmp/optimization/walk_forward_folds_<timestamp>.csv`
- recommended config JSON: `tmp/optimization/recommended_config_<timestamp>.json`

---

## Recommended Config JSON

The JSON includes:

- `stable_params`
- source window metadata (segment/symbol/interval/from/to)
- walk-forward settings
- full-period metrics

Use it as a persisted calibration artifact for deployment or repeatable runs.

Note: JSON metadata includes resolved instrument details from DhanHQ (including `security_id`), but runtime input remains `exchange-segment + symbol`.

---

## Date Handling

- `to_date` is always current day.
- `from_date` is computed as `today - days`.
- Weekend dates are adjusted to nearest prior trading day before API call.

This avoids DhanHQ validation failures for non-trading dates.

---

## Tests

Run:

```bash
rspec spec/signal_generator_spec.rb
```

Current coverage in this repo focuses on:

- ATR/RSI/DMI/SuperTrend primitives
- signal validity and strategy invariants
- timeframe-derived threshold behavior

---

## Scoring (Optimization)

Search and calibration use a composite score over:

- net PnL
- win rate
- profit factor (capped influence)
- drawdown penalty
- minimum trade count requirement

Tune constraint/score behavior in `lib/strategy_optimization.rb`.

---

## Troubleshooting

- **Instrument not found**
  - Verify `--exchange-segment` and `--symbol` match Dhan instrument master.
- **Dhan auth error**
  - Ensure `DHAN_CLIENT_ID` and `DHAN_ACCESS_TOKEN` are valid.
- **Weekend date validation**
  - Handled automatically; if issue persists, retry during market day with recent `--days`.
- **No folds produced**
  - Increase `--days` or reduce `--train-days` / `--validate-days`.
- **No config passes constraints**
  - Relax `--min-trades` or increase `--max-drawdown`.

---

## Notes

- This repo is strategy research tooling, not an order execution engine.
- Keep optimization out-of-sample discipline: prefer walk-forward stability over single-run best score.

