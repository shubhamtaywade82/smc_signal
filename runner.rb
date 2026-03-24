#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage:
#   # From DhanHQ API:
#   ruby runner.rb --source api --security-id 13 --segment NSE_EQ \
#                  --instrument INDEX --interval 5 \
#                  --from 2024-01-01 --to 2024-03-01
#
#   # From saved JSON file:
#   ruby runner.rb --source json --file ./data/nifty_5m.json
#
#   # From CSV:
#   ruby runner.rb --source csv --file ./data/nifty_5m.csv
#
# Optional flags:
#   --tf-minutes 5       (default: 5, drives dynamic thresholds)
#   --signals-only       (only print bars where signal != HOLD)
#   --last N             (only show last N bars)

$LOAD_PATH.unshift File.join(__dir__, "lib")

require "optparse"
require "json"
require "super_trend_signal_generator"
require "dhan_hq/historical_client"

options = {
  source:     "json",
  tf_minutes: 5,
  signals_only: false,
  last:       nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby runner.rb [options]"

  opts.on("--source SRC",     "api | json | csv")          { |v| options[:source] = v }
  opts.on("--file PATH",      "Path to JSON or CSV file")  { |v| options[:file] = v }
  opts.on("--security-id ID", "DhanHQ security_id")        { |v| options[:security_id] = v }
  opts.on("--segment SEG",    "Exchange segment")          { |v| options[:segment] = v }
  opts.on("--instrument INS", "Instrument type")           { |v| options[:instrument] = v }
  opts.on("--interval INT",   "Candle interval (1,5,15…)") { |v| options[:interval] = v }
  opts.on("--from DATE",      "From date YYYY-MM-DD")      { |v| options[:from] = v }
  opts.on("--to DATE",        "To date YYYY-MM-DD")        { |v| options[:to] = v }
  opts.on("--tf-minutes N",   Integer, "Timeframe minutes"){ |v| options[:tf_minutes] = v }
  opts.on("--signals-only",   "Only print non-HOLD bars")  { options[:signals_only] = true }
  opts.on("--last N",         Integer, "Show last N bars") { |v| options[:last] = v }
end.parse!

# ── Load bars ──────────────────────────────────────────────────────────────
bars = case options[:source]
       when "api"
         %i[security_id segment instrument interval from to].each do |k|
           abort "Missing --#{k.to_s.tr('_', '-')}" if options[k].nil?
         end

         client = DhanHQ::HistoricalClient.new(
           access_token: ENV.fetch("DHAN_ACCESS_TOKEN") { abort "DHAN_ACCESS_TOKEN not set" },
           client_id:    ENV.fetch("DHAN_CLIENT_ID")    { abort "DHAN_CLIENT_ID not set" }
         )
         client.fetch(
           security_id:      options[:security_id],
           exchange_segment: options[:segment],
           instrument_type:  options[:instrument],
           interval:         options[:interval],
           from_date:        options[:from],
           to_date:          options[:to]
         )

       when "json"
         abort "Missing --file" unless options[:file]
         client = DhanHQ::HistoricalClient.new(access_token: "", client_id: "")
         client.load_json(options[:file])

       when "csv"
         abort "Missing --file" unless options[:file]
         client = DhanHQ::HistoricalClient.new(access_token: "", client_id: "")
         client.load_csv(options[:file])

       else
         abort "Unknown source: #{options[:source]}"
       end

abort "No bars loaded" if bars.empty?
puts "Loaded #{bars.size} bars"

# ── Generate signals ────────────────────────────────────────────────────────
generator = SuperTrendSignalGenerator.new(tf_minutes: options[:tf_minutes])
results   = generator.generate(bars)

# Filter and slice
results = results.reject { |r| r[:warmup] }
results = results.select { |r| r[:signal] != "HOLD" } if options[:signals_only]
results = results.last(options[:last]) if options[:last]

# ── Print ───────────────────────────────────────────────────────────────────
puts "\n#{"BAR"<9} #{"TIMESTAMP"<22} #{"CLOSE"<10} #{"SIGNAL"<22} #{"RSI"<8} #{"ADX"<8} #{"ATR%"<8} #{"ST_DIR"<8} #{"MODE"}"
puts "-" * 120

results.each do |r|
  ts     = r[:timestamp]&.strftime("%Y-%m-%d %H:%M") || "—"
  signal = r[:signal] || "—"
  color  = case signal
           when "BUY CALLS"         then "\e[32m"   # green
           when "BUY PUTS"          then "\e[31m"   # red
           when /BOOK/              then "\e[33m"   # yellow
           else                          "\e[0m"
           end
  reset  = "\e[0m"
  dir    = r[:st_direction] == -1 ? "BULL" : "BEAR"

  printf "#{color}%-9s %-22s %-10s %-22s %-8s %-8s %-8s %-8s %s#{reset}\n",
         r[:bar_index],
         ts,
         r[:close],
         signal,
         r[:rsi],
         r[:adx],
         r[:atr_pct],
         dir,
         r[:market_mode]
end

# ── Summary ─────────────────────────────────────────────────────────────────
call_bars  = results.count { |r| r[:signal] == "BUY CALLS" }
put_bars   = results.count { |r| r[:signal] == "BUY PUTS" }
book_bars  = results.count { |r| r[:signal]&.include?("BOOK") }
hold_bars  = results.count { |r| r[:signal] == "HOLD" }

puts "\n── Summary ──────────────────────────────────────────────"
puts "  BUY CALLS:         #{call_bars}"
puts "  BUY PUTS:          #{put_bars}"
puts "  BOOK PROFITS:      #{book_bars}"
puts "  HOLD:              #{hold_bars}"
puts "  Total signal bars: #{results.size}"