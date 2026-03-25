# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "..", "lib")

require "options_buying_policy"
require "live_option_selector"

RSpec.describe OptionsBuyingPolicy do
  subject(:policy) { described_class.new }

  it "returns no_trade for non-buy signals" do
    result = policy.recommendation(signal: "HOLD", adx: 30, atr_pct: 0.04)
    expect(result[:decision]).to eq(:no_trade)
  end

  it "returns no_trade when adx is below threshold" do
    result = policy.recommendation(signal: "BUY CALLS", adx: 15, atr_pct: 0.04)
    expect(result[:decision]).to eq(:no_trade)
  end

  it "returns CE recommendation for buy calls" do
    result = policy.recommendation(signal: "BUY CALLS", adx: 30, atr_pct: 0.03)
    expect(result[:decision]).to eq(:buy_option)
    expect(result[:side]).to eq(:ce)
  end

  it "uses calibrated preferred moneyness when configured" do
    calibrated_policy = described_class.new(config: { preferred_moneyness: { ce: :itm, pe: :otm } })
    result = calibrated_policy.recommendation(signal: "BUY CALLS", adx: 30, atr_pct: 0.03)
    expect(result[:moneyness]).to eq(:itm)
  end
end

RSpec.describe LiveOptionSelector do
  subject(:selector) { described_class.new }

  let(:option_chain) do
    {
      "24900" => {
        "ce" => { "last_price" => 90.0, "best_bid_price" => 89.5, "best_ask_price" => 90.5, "oi" => 12_000, "volume" => 6_000 },
        "pe" => { "last_price" => 40.0, "best_bid_price" => 39.5, "best_ask_price" => 40.5, "oi" => 11_000, "volume" => 5_500 }
      },
      "25000" => {
        "ce" => { "last_price" => 70.0, "best_bid_price" => 69.5, "best_ask_price" => 70.5, "oi" => 13_000, "volume" => 7_000 },
        "pe" => { "last_price" => 60.0, "best_bid_price" => 59.5, "best_ask_price" => 60.5, "oi" => 12_500, "volume" => 6_500 }
      }
    }
  end

  it "selects a contract for CE side" do
    result = selector.select(option_chain: option_chain, side: :ce, moneyness: :atm, spot_price: 25_010)
    expect(result).not_to be_nil
    expect(result[:strike]).to eq(25_000.0)
  end

  it "returns nil when all contracts fail liquidity filters" do
    illiquid_chain = {
      "25000" => {
        "ce" => { "last_price" => 70.0, "best_bid_price" => 60.0, "best_ask_price" => 80.0, "oi" => 100, "volume" => 50 },
        "pe" => { "last_price" => 60.0, "best_bid_price" => 50.0, "best_ask_price" => 70.0, "oi" => 80, "volume" => 40 }
      }
    }
    result = selector.select(option_chain: illiquid_chain, side: :ce, moneyness: :atm, spot_price: 25_000)
    expect(result).to be_nil
  end
end
