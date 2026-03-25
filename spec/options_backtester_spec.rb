# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "..", "lib")

require "time"
require "options_backtester"

RSpec.describe OptionsBacktester do
  let(:instrument) { Struct.new(:security_id).new("13") }
  let(:base_time) { Time.parse("2026-03-01 09:15:00") }

  def signal_at(offset, signal)
    { timestamp: base_time + (offset * 60), signal: signal, adx: 30.0, atr_pct: 0.03 }
  end

  def candle_at(offset, open:, high:, low:, close:, oi: 5000, volume: 1000)
    {
      timestamp: base_time + (offset * 60),
      open: open,
      high: high,
      low: low,
      close: close,
      open_interest: oi,
      volume: volume
    }
  end

  it "enters on next candle open and exits on take profit first" do
    candles = [
      candle_at(1, open: 100, high: 102, low: 99, close: 101),
      candle_at(2, open: 101, high: 170, low: 100, close: 160)
    ]
    provider = ->(**_) { candles }
    backtester = described_class.new(option_data_provider: provider, config: { risk: { sl_pct: 0.10, tp_pct: 0.20, max_hold_bars: 5 } })
    result = backtester.run(instrument: instrument, signals: [signal_at(0, "BUY CALLS")], interval: "1")

    expect(result[:trades].size).to eq(1)
    trade = result[:trades].first
    expect(trade[:entry_time]).to eq(candle_at(1, open: 0, high: 0, low: 0, close: 0)[:timestamp])
    expect(trade[:exit_reason]).to eq("take_profit")
  end

  it "exits on stop loss first when low breaches threshold" do
    candles = [
      candle_at(1, open: 100, high: 103, low: 99, close: 101),
      candle_at(2, open: 100, high: 102, low: 80, close: 81)
    ]
    provider = ->(**_) { candles }
    backtester = described_class.new(option_data_provider: provider, config: { risk: { sl_pct: 0.10, tp_pct: 0.50, max_hold_bars: 5 } })
    result = backtester.run(instrument: instrument, signals: [signal_at(0, "BUY CALLS")], interval: "1")

    expect(result[:trades].first[:exit_reason]).to eq("stop_loss")
  end

  it "exits on signal flip when sl tp not hit" do
    candles = [
      candle_at(1, open: 100, high: 101, low: 99, close: 100.5),
      candle_at(2, open: 100.5, high: 101, low: 100, close: 100.7),
      candle_at(3, open: 100.7, high: 101, low: 100.4, close: 100.6)
    ]
    provider = ->(**_) { candles }
    backtester = described_class.new(option_data_provider: provider, config: { risk: { sl_pct: 0.50, tp_pct: 0.50, max_hold_bars: 5 } })
    signals = [signal_at(0, "BUY CALLS"), signal_at(2, "BUY PUTS")]
    result = backtester.run(instrument: instrument, signals: signals, interval: "1")

    expect(result[:trades].first[:exit_reason]).to eq("signal_flip")
  end

  it "exits on max hold bars when no other condition triggers" do
    candles = [
      candle_at(1, open: 100, high: 101, low: 99.5, close: 100.2),
      candle_at(2, open: 100.2, high: 101, low: 99.6, close: 100.1),
      candle_at(3, open: 100.1, high: 100.8, low: 99.7, close: 100.0)
    ]
    provider = ->(**_) { candles }
    backtester = described_class.new(option_data_provider: provider, config: { risk: { sl_pct: 0.50, tp_pct: 0.50, max_hold_bars: 2 } })
    result = backtester.run(instrument: instrument, signals: [signal_at(0, "BUY CALLS")], interval: "1")

    expect(result[:trades].first[:exit_reason]).to eq("max_hold_bars")
  end

  it "skips entry when liquidity is below threshold" do
    candles = [
      candle_at(1, open: 100, high: 105, low: 95, close: 101, oi: 100, volume: 20),
      candle_at(2, open: 101, high: 103, low: 99, close: 102, oi: 100, volume: 20)
    ]
    provider = ->(**_) { candles }
    backtester = described_class.new(option_data_provider: provider, config: { liquidity: { min_oi: 1000, max_spread_pct: 2.0 } })
    result = backtester.run(instrument: instrument, signals: [signal_at(0, "BUY CALLS")], interval: "1")

    expect(result[:trades]).to be_empty
    expect(result[:summary][:skipped_signals]).to eq(1)
  end

  it "computes summary metrics from completed trades" do
    candles = [
      candle_at(1, open: 100, high: 100, low: 100, close: 100),
      candle_at(2, open: 100, high: 140, low: 95, close: 120),
      candle_at(5, open: 100, high: 101, low: 99, close: 100),
      candle_at(6, open: 100, high: 101, low: 60, close: 70)
    ]

    provider = lambda do |option_type:, **_|
      if option_type == "CALL"
        candles[0..1]
      else
        candles[2..3]
      end
    end

    backtester = described_class.new(option_data_provider: provider, config: { risk: { sl_pct: 0.20, tp_pct: 0.20, max_hold_bars: 2 } })
    signals = [signal_at(0, "BUY CALLS"), signal_at(4, "BUY PUTS")]
    result = backtester.run(instrument: instrument, signals: signals, interval: "1")

    expect(result[:summary][:trades]).to eq(2)
    expect(result[:summary][:profit_factor]).to be >= 0.0
    expect(result[:summary]).to have_key(:max_drawdown)
  end
end
