# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "..", "lib")

require "indicators/primitives"
require "indicators/super_trend2"
require "indicators/dmi"
require "super_trend_signal_generator"

RSpec.describe Indicators::ATR do
  subject { described_class.new(length: 3) }

  let(:bars) do
    [
      { high: 110, low: 100, close: 105 },
      { high: 112, low: 102, close: 108 },
      { high: 115, low: 107, close: 113 },
      { high: 114, low: 109, close: 111 },
      { high: 116, low: 110, close: 115 }
    ]
  end

  it "returns nil for the first bar" do
    expect(subject.calculate(bars).first).to be_nil
  end

  it "returns numeric values for subsequent bars" do
    results = subject.calculate(bars)
    expect(results[1..].all? { |v| v.is_a?(Numeric) }).to be true
  end

  it "ATR is always positive" do
    results = subject.calculate(bars).compact
    expect(results.all? { |v| v > 0 }).to be true
  end

  it "second bar ATR is the raw TR (Wilder seed)" do
    # TR on bar[1] = max(112-102, |112-105|, |102-105|) = max(10, 7, 3) = 10
    results = subject.calculate(bars)
    expect(results[1]).to eq(10)
  end
end

RSpec.describe Indicators::RSI do
  subject { described_class.new(length: 3) }

  let(:closes) { [10.0, 11.0, 10.5, 12.0, 11.0, 13.0, 14.0] }

  it "returns nil for first bar" do
    results = subject.calculate(closes)
    expect(results.first).to be_nil
  end

  it "returns values in 0..100 range" do
    results = subject.calculate(closes).compact
    expect(results.all? { |v| v >= 0 && v <= 100 }).to be true
  end

  it "RSI is higher on upward streak than downward" do
    up_closes   = [10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0]
    down_closes = [16.0, 15.0, 14.0, 13.0, 12.0, 11.0, 10.0]
    up_rsi   = subject.calculate(up_closes).compact.last
    down_rsi = subject.calculate(down_closes).compact.last
    expect(up_rsi).to be > down_rsi
  end
end

RSpec.describe Indicators::DMI do
  subject { described_class.new(length: 3, smoothing: 3) }

  let(:bars) do
    [
      { high: 110, low: 100, close: 105 },
      { high: 115, low: 105, close: 112 },
      { high: 118, low: 108, close: 116 },
      { high: 120, low: 112, close: 118 },
      { high: 119, low: 110, close: 113 },
      { high: 117, low: 108, close: 110 },
      { high: 116, low: 106, close: 108 }
    ]
  end

  it "returns empty hash for first bar (seed bar)" do
    expect(subject.calculate(bars).first).to eq({})
  end

  it "computes positive diplus and diminus" do
    results = subject.calculate(bars).select { |r| r.is_a?(Hash) && r[:diplus] }
    expect(results.all? { |r| r[:diplus] >= 0 && r[:diminus] >= 0 }).to be true
  end

  it "ADX is positive" do
    results = subject.calculate(bars).select { |r| r.is_a?(Hash) && r[:adx] }
    expect(results.all? { |r| r[:adx] >= 0 }).to be true
  end

  it "diplus > diminus on strong uptrend bars" do
    results = subject.calculate(bars).select { |r| r.is_a?(Hash) && r[:diplus] }
    expect(results.first[:diplus]).to be > results.first[:diminus]
  end
end

RSpec.describe Indicators::SuperTrend2 do
  subject { described_class.new(factor: 2.0, use_wicks: true) }

  def make_bars(n, trend: :up)
    base = 100.0
    n.times.map do |i|
      delta = trend == :up ? i * 0.5 : -i * 0.5
      { high: base + delta + 1.5, low: base + delta - 1.5, close: base + delta, atr: 2.0 }
    end
  end

  it "returns one result per bar" do
    expect(subject.calculate(make_bars(10)).size).to eq(10)
  end

  it "goes bullish on sustained uptrend" do
    expect(subject.calculate(make_bars(30, trend: :up)).last[:direction]).to eq(-1)
  end

  it "goes bearish on sustained downtrend" do
    expect(subject.calculate(make_bars(30, trend: :down)).last[:direction]).to eq(1)
  end

  it "ST line is below price in bullish mode" do
    bars    = make_bars(30, trend: :up)
    results = subject.calculate(bars)
    last    = results.last
    expect(last[:st]).to be < bars.last[:close] if last[:direction] == -1
  end
end

RSpec.describe SuperTrendSignalGenerator do
  subject { described_class.new(tf_minutes: 5) }

  def synthetic_bars(n, trend: :up)
    base = 25_000.0
    srand(42)
    n.times.map do |i|
      delta = trend == :up ? i * 5 : -i * 5
      { timestamp: Time.now - (n - i) * 300,
        open: base + delta - 2, high: base + delta + 10,
        low: base + delta - 10, close: base + delta,
        volume: 100_000 + rand(50_000) }
    end
  end

  it "returns one result per bar" do
    expect(subject.generate(synthetic_bars(50)).size).to eq(50)
  end

  it "marks warm-up bars" do
    results = subject.generate(synthetic_bars(10))
    expect(results.count { |r| r[:warmup] }).to be > 0
  end

  it "signal is one of the valid values for non-warmup bars" do
    valid   = ["BUY CALLS", "BUY PUTS", "BOOK CALL PROFITS", "BOOK PUT PROFITS", "HOLD"]
    results = subject.generate(synthetic_bars(100)).reject { |r| r[:warmup] }
    expect(results.all? { |r| valid.include?(r[:signal]) }).to be true
  end

  it "every result has required keys" do
    required = %i[bar_index timestamp close signal]
    results  = subject.generate(synthetic_bars(60)).reject { |r| r[:warmup] }
    results.each do |r|
      required.each { |k| expect(r).to have_key(k) }
    end
  end

  it "derives correct RSI buy_min for 5m" do
    expect(subject.instance_variable_get(:@rsi_buy_min)).to eq(35)
  end

  it "dir_confirm is false for 5m (< 15)" do
    expect(subject.instance_variable_get(:@dir_confirm)).to be false
  end

  it "dir_confirm is true for 15m" do
    gen = described_class.new(tf_minutes: 15)
    expect(gen.instance_variable_get(:@dir_confirm)).to be true
  end

  it "uses higher RSI thresholds for 1H" do
    gen = described_class.new(tf_minutes: 60)
    expect(gen.instance_variable_get(:@rsi_buy_min)).to eq(40)
    expect(gen.instance_variable_get(:@trend_level)).to eq(35)
  end

  it "call_buy signals always have st_bullish=true" do
    results = subject.generate(synthetic_bars(100)).reject { |r| r[:warmup] }
    results.select { |r| r[:signal] == "BUY CALLS" }.each do |r|
      expect(r[:st_bullish]).to be true
    end
  end

  it "put_buy signals always have st_bullish=false" do
    results = subject.generate(synthetic_bars(100, trend: :down)).reject { |r| r[:warmup] }
    results.select { |r| r[:signal] == "BUY PUTS" }.each do |r|
      expect(r[:st_bullish]).to be false
    end
  end

  it "does not emit more call exits than call entries" do
    results = subject.generate(synthetic_bars(150)).reject { |row| row[:warmup] }
    call_entries = results.count { |row| row[:signal] == "BUY CALLS" }
    call_exits = results.count { |row| row[:signal] == "BOOK CALL PROFITS" }

    expect(call_exits).to be <= call_entries
  end

  it "does not emit more put exits than put entries" do
    results = subject.generate(synthetic_bars(150, trend: :down)).reject { |row| row[:warmup] }
    put_entries = results.count { |row| row[:signal] == "BUY PUTS" }
    put_exits = results.count { |row| row[:signal] == "BOOK PUT PROFITS" }

    expect(put_exits).to be <= put_entries
  end
end