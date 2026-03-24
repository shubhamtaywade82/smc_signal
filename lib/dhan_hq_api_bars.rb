# frozen_string_literal: true

require "date"

class DhanHqApiBars
  DEFAULT_CLIENT_PATH = File.expand_path("../../dhanhq-client", __dir__)

  def initialize(client_path: ENV["DHANHQ_CLIENT_PATH"] || DEFAULT_CLIENT_PATH)
    require File.join(client_path, "lib", "dhan_hq")
    DhanHQ.configure_with_env
  end

  def fetch(exchange_segment:, symbol:, interval:, days:)
    instrument = DhanHQ::Models::Instrument.find(exchange_segment, symbol, exact_match: true)
    raise ArgumentError, "Instrument not found for #{exchange_segment}:#{symbol}" if instrument.nil?

    to_date = nearest_trading_day(Date.today)
    from_date = nearest_trading_day(to_date - days.to_i)
    bars = instrument.intraday(
      from_date: from_date.strftime("%Y-%m-%d"),
      to_date: to_date.strftime("%Y-%m-%d"),
      interval: interval.to_s
    )

    { instrument: instrument, bars: bars, from_date: from_date, to_date: to_date }
  end

  private

  def nearest_trading_day(date)
    return date - 1 if date.saturday?
    return date - 2 if date.sunday?

    date
  end
end
