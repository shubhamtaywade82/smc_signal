# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "time"

module DhanHQ
  # Fetches historical OHLCV candles from DhanHQ v2 API.
  #
  # Endpoint: POST /v2/charts/historical
  # Docs: https://dhanhq.co/docs/v2/historical-data/
  #
  # Usage:
  #   client = DhanHQ::HistoricalClient.new(access_token: ENV["DHAN_ACCESS_TOKEN"], client_id: ENV["DHAN_CLIENT_ID"])
  #   bars   = client.fetch(security_id: "13", exchange_segment: "NSE_EQ", instrument_type: "INDEX", interval: "5", from_date: "2024-01-01", to_date: "2024-03-01")
  class HistoricalClient
    BASE_URL = "https://api.dhan.co"

    INTERVALS = {
      "1"    => "1",
      "5"    => "5",
      "15"   => "15",
      "25"   => "25",
      "60"   => "60",
      "D"    => "D",
      "W"    => "W",
      "M"    => "M"
    }.freeze

    # DhanHQ security IDs for common indices
    SECURITY_IDS = {
      nifty50:  "13",
      banknifty: "25",
      sensex:   "51"
    }.freeze

    def initialize(access_token:, client_id:)
      @access_token = access_token
      @client_id    = client_id
    end

    # @param security_id [String]     DhanHQ security_id ("13" for NIFTY)
    # @param exchange_segment [String] "NSE_EQ" | "BSE_EQ" | "NSE_FNO" etc
    # @param instrument_type [String]  "INDEX" | "EQUITY" | "FUTIDX" etc
    # @param interval [String]         "1" | "5" | "15" | "25" | "60" | "D" | "W" | "M"
    # @param from_date [String]        "YYYY-MM-DD"
    # @param to_date [String]          "YYYY-MM-DD"
    # @return [Array<Hash>] normalized OHLCV bars
    def fetch(security_id:, exchange_segment:, instrument_type:, interval:, from_date:, to_date:)
      payload = {
        securityId:      security_id,
        exchangeSegment: exchange_segment,
        instrument:      instrument_type,
        expiryCode:      0,
        oi_flag:         "0",
        fromDate:        from_date,
        toDate:          to_date
      }

      endpoint = interval == "D" || interval == "W" || interval == "M" \
                 ? "/v2/charts/historical" \
                 : "/v2/charts/intraday"

      if endpoint == "/v2/charts/intraday"
        payload[:interval] = interval
      end

      response = post(endpoint, payload)
      parse_response(response)
    end

    # Load from a JSON file (DhanHQ historical API response saved to disk)
    # @param path [String] path to JSON file
    def load_json(path)
      raw = JSON.parse(File.read(path), symbolize_names: true)
      parse_response(raw)
    end

    # Load from CSV (columns: timestamp,open,high,low,close,volume)
    # @param path [String]
    def load_csv(path)
      require "csv"
      bars = []
      CSV.foreach(path, headers: true) do |row|
        bars << {
          timestamp: Time.parse(row["timestamp"]),
          open:      row["open"].to_f,
          high:      row["high"].to_f,
          low:       row["low"].to_f,
          close:     row["close"].to_f,
          volume:    row["volume"].to_i
        }
      end
      bars
    end

    private

    def post(endpoint, payload)
      uri  = URI("#{BASE_URL}#{endpoint}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30

      req = Net::HTTP::Post.new(uri)
      req["Content-Type"]  = "application/json"
      req["access-token"]  = @access_token
      req["client-id"]     = @client_id

      req.body = payload.to_json

      resp = http.request(req)

      raise "DhanHQ API error #{resp.code}: #{resp.body}" unless resp.code == "200"

      JSON.parse(resp.body, symbolize_names: true)
    end

    # DhanHQ returns parallel arrays: open[], high[], low[], close[], volume[], timestamp[]
    def parse_response(data)
      opens      = data[:open]      || data["open"]
      highs      = data[:high]      || data["high"]
      lows       = data[:low]       || data["low"]
      closes     = data[:close]     || data["close"]
      volumes    = data[:volume]    || data["volume"]
      timestamps = data[:timestamp] || data["timestamp"] || data[:start_Time] || data["start_Time"]

      raise "Invalid DhanHQ response — missing OHLCV arrays" if opens.nil? || closes.nil?

      opens.size.times.map do |i|
        {
          timestamp: timestamps ? Time.at(timestamps[i].to_i) : nil,
          open:      opens[i].to_f,
          high:      highs[i].to_f,
          low:       lows[i].to_f,
          close:     closes[i].to_f,
          volume:    volumes ? volumes[i].to_i : 0
        }
      end
    end
  end
end