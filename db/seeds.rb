# frozen_string_literal: true

require 'benchmark'

time = Benchmark.realtime do
  Oaken.loader.seed :users
  Oaken.loader.seed :proxies
  Oaken.loader.seed :sources
  Oaken.loader.seed :vacancies
end

puts "Time to create seeds: #{time.round(3)} seconds" # rubocop:disable Rails/Output
