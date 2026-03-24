#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.join(__dir__, "..", "lib")

require "optparse"
require "fileutils"
require "strategy_optimization"

options = {
  source: "api",
  tf_minutes: 1,
  trials: 300,
  seed: 42,
  top: 20,
  min_trades: 3,
  max_drawdown: 1_000_000.0,
  out_dir: File.join(__dir__, "..", "tmp", "optimization")
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/optimize.rb [options]"
  opts.on("--source SRC", "api | json | csv") { |value| options[:source] = value }
  opts.on("--file PATH", "Path to JSON/CSV file") { |value| options[:file] = value }
  opts.on("--security-id ID", "DhanHQ security_id") { |value| options[:security_id] = value }
  opts.on("--segment SEG", "Exchange segment") { |value| options[:segment] = value }
  opts.on("--instrument INS", "Instrument type") { |value| options[:instrument] = value }
  opts.on("--interval INT", "Candle interval in minutes") { |value| options[:interval] = value }
  opts.on("--from DATE", "From date YYYY-MM-DD") { |value| options[:from] = value }
  opts.on("--to DATE", "To date YYYY-MM-DD") { |value| options[:to] = value }
  opts.on("--tf-minutes N", Integer, "Strategy timeframe minutes") { |value| options[:tf_minutes] = value }
  opts.on("--trials N", Integer, "Random parameter combinations") { |value| options[:trials] = value }
  opts.on("--seed N", Integer, "Random seed") { |value| options[:seed] = value }
  opts.on("--top N", Integer, "Top rows to print") { |value| options[:top] = value }
  opts.on("--min-trades N", Integer, "Reject configs below trade count") { |value| options[:min_trades] = value }
  opts.on("--max-drawdown N", Float, "Reject configs above drawdown") { |value| options[:max_drawdown] = value }
  opts.on("--out-dir DIR", "Output directory for CSV") { |value| options[:out_dir] = value }
end.parse!

StrategyOptimization.load_env!(File.expand_path("..", __dir__))

bars = StrategyOptimization.load_bars(
  source: options[:source],
  file: options[:file],
  security_id: options[:security_id],
  segment: options[:segment],
  instrument: options[:instrument],
  interval: options[:interval],
  from: options[:from],
  to: options[:to]
)

abort "No bars loaded" if bars.empty?

rng = Random.new(options[:seed])
configs = StrategyOptimization.sample_configs(trials: options[:trials], rng: rng)
results = configs.map do |params|
  StrategyOptimization.evaluate_config(
    bars: bars,
    tf_minutes: options[:tf_minutes],
    params: params
  )
end

filtered = results.select do |row|
  StrategyOptimization.constraints_satisfied?(
    row,
    min_trades: options[:min_trades],
    max_drawdown: options[:max_drawdown]
  )
end

abort "No configurations satisfied constraints (min_trades=#{options[:min_trades]}, max_drawdown=#{options[:max_drawdown]})" if filtered.empty?

ranked = filtered.sort_by { |row| -row[:score] }
top_rows = ranked.first(options[:top]).map { |row| StrategyOptimization.flatten_result(row) }

FileUtils.mkdir_p(options[:out_dir])
timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
csv_path = File.join(options[:out_dir], "optimize_#{timestamp}.csv")
StrategyOptimization.write_results_csv(csv_path, ranked.map { |row| StrategyOptimization.flatten_result(row) })

puts "Loaded bars: #{bars.size}"
puts "Trials: #{options[:trials]}"
puts "Passing constraints: #{filtered.size}/#{results.size}"
puts "Best score: #{ranked.first[:score].round(4)}"
puts "Best params: #{ranked.first[:params]}"
puts "CSV: #{csv_path}"
puts
puts "Top #{top_rows.size} configs:"
top_rows.each_with_index do |row, index|
  puts format(
    "%2d) score=%10.2f net=%10.2f dd=%10.2f trades=%4d win_rate=%6.2f%% pf=%5.2f params=%s",
    index + 1,
    row[:score],
    row[:net_pnl],
    row[:max_drawdown],
    row[:trade_count],
    row[:win_rate] * 100.0,
    row[:profit_factor],
    ranked[index][:params]
  )
end
