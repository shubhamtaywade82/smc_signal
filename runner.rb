#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage:
#   # From DhanHQ API:
#   ruby runner.rb --source api --security-id 13 --segment NSE_EQ --instrument INDEX --interval 5 --from 2024-01-01 --to 2024-03-01
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
env_file = File.join(__dir__, ".env")
if File.file?(env_file)
  File.foreach(env_file) do |line|
    next if line.strip.empty? || line.start_with?("#")

    key, value = line.strip.split("=", 2)
    ENV[key] ||= value
  end
end

$LOAD_PATH.unshift File.join(__dir__, "lib")

require "optparse"
require "json"
require "super_trend_signal_generator"
require "dhan_hq/historical_client"

DEFAULT_OPTIONS = {
  source: "json",
  tf_minutes: 5,
  signals_only: false,
  summary_only: false,
  no_color: false,
  last: nil
}.freeze

def parse_options
  options = DEFAULT_OPTIONS.dup

  OptionParser.new do |opts|
    opts.banner = "Usage: ruby runner.rb [options]"
    opts.on("--source SRC", "api | json | csv") { |v| options[:source] = v }
    opts.on("--file PATH", "Path to JSON or CSV file") { |v| options[:file] = v }
    opts.on("--security-id ID", "DhanHQ security_id") { |v| options[:security_id] = v }
    opts.on("--segment SEG", "Exchange segment") { |v| options[:segment] = v }
    opts.on("--instrument INS", "Instrument type") { |v| options[:instrument] = v }
    opts.on("--interval INT", "Candle interval (1,5,15...)") { |v| options[:interval] = v }
    opts.on("--from DATE", "From date YYYY-MM-DD") { |v| options[:from] = v }
    opts.on("--to DATE", "To date YYYY-MM-DD") { |v| options[:to] = v }
    opts.on("--tf-minutes N", Integer, "Timeframe minutes") { |v| options[:tf_minutes] = v }
    opts.on("--signals-only", "Only print non-HOLD bars") { options[:signals_only] = true }
    opts.on("--summary-only", "Skip row output, print only summary") { options[:summary_only] = true }
    opts.on("--no-color", "Disable ANSI colors") { options[:no_color] = true }
    opts.on("--last N", Integer, "Show last N bars") { |v| options[:last] = v }
  end.parse!

  options
end

def load_bars(options)
  case options[:source]
  when "api"
    validate_api_options!(options)
    fetch_api_bars(options)
  when "json"
    abort "Missing --file" unless options[:file]

    local_client.load_json(options[:file])
  when "csv"
    abort "Missing --file" unless options[:file]

    local_client.load_csv(options[:file])
  else
    abort "Unknown source: #{options[:source]}"
  end
end

def validate_api_options!(options)
  %i[security_id segment instrument interval from to].each do |key|
    abort "Missing --#{key.to_s.tr('_', '-')}" if options[key].nil?
  end
end

def fetch_api_bars(options)
  api_client.fetch(
    security_id: options[:security_id],
    exchange_segment: options[:segment],
    instrument_type: options[:instrument],
    interval: options[:interval],
    from_date: options[:from],
    to_date: options[:to]
  )
end

def api_client
  DhanHQ::HistoricalClient.new(
    access_token: ENV.fetch("DHAN_ACCESS_TOKEN") { abort "DHAN_ACCESS_TOKEN not set" },
    client_id: ENV.fetch("DHAN_CLIENT_ID") { abort "DHAN_CLIENT_ID not set" }
  )
end

def local_client
  DhanHQ::HistoricalClient.new(access_token: "", client_id: "")
end

def filter_results(results, options)
  filtered_results = results.reject { |result| result[:warmup] }
  filtered_results = filtered_results.select { |result| result[:signal] != "HOLD" } if options[:signals_only]
  filtered_results = filtered_results.last(options[:last]) if options[:last]
  filtered_results
end

def print_rows(results, options)
  return if options[:summary_only]

  puts "\n#{'BAR'.ljust(9)} #{'TIMESTAMP'.ljust(22)} #{'CLOSE'.ljust(10)} #{'SIGNAL'.ljust(22)} #{'RSI'.ljust(8)} #{'ADX'.ljust(8)} #{'ATR%'.ljust(8)} #{'ST_DIR'.ljust(8)} MODE"
  puts "-" * 120

  results.each do |result|
    timestamp = result[:timestamp]&.strftime("%Y-%m-%d %H:%M") || "-"
    signal = result[:signal] || "-"
    direction = result[:st_direction] == -1 ? "BULL" : "BEAR"
    color = signal_color(signal, options)
    reset = color.empty? ? "" : "\e[0m"

    printf "#{color}%-9s %-22s %-10s %-22s %-8s %-8s %-8s %-8s %s#{reset}\n",
           result[:bar_index],
           timestamp,
           result[:close],
           signal,
           result[:rsi],
           result[:adx],
           result[:atr_pct],
           direction,
           result[:market_mode]
  end
end

def signal_color(signal, options)
  return "" if options[:no_color] || !STDOUT.tty?

  case signal
  when "BUY CALLS"
    "\e[32m"
  when "BUY PUTS"
    "\e[31m"
  when /BOOK/
    "\e[33m"
  else
    ""
  end
end

def print_summary(results)
  buy_call_count = results.count { |result| result[:signal] == "BUY CALLS" }
  buy_put_count = results.count { |result| result[:signal] == "BUY PUTS" }
  booked_profit_count = results.count { |result| result[:signal]&.include?("BOOK") }
  hold_count = results.count { |result| result[:signal] == "HOLD" }

  puts "\n-- Summary --------------------------------------------------"
  puts "  BUY CALLS:         #{buy_call_count}"
  puts "  BUY PUTS:          #{buy_put_count}"
  puts "  BOOK PROFITS:      #{booked_profit_count}"
  puts "  HOLD:              #{hold_count}"
  puts "  Total signal bars: #{results.size}"
end

options = parse_options
bars = load_bars(options)
abort "No bars loaded" if bars.empty?

puts "Loaded #{bars.size} bars"

generator = SuperTrendSignalGenerator.new(tf_minutes: options[:tf_minutes])
results = filter_results(generator.generate(bars), options)

print_rows(results, options)
print_summary(results)