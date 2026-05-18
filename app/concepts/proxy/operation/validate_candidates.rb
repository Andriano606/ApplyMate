# frozen_string_literal: true

require 'async'

class Proxy::Operation::ValidateCandidates < ApplyMate::Operation::Base
  include ApplyMate::Logging

  VALIDATION_CONCURRENCY = Integer(ENV.fetch('FETCH_PROXIES_VALIDATION_CONCURRENCY', '5000'))
  VALID_PROTOCOLS        = %w[http https socks5 socks5h].freeze
  VALIDATION_ATTEMPTS    = Integer(ENV.fetch('FETCH_PROXIES_VALIDATION_ATTEMPTS', '20'))
  VALIDATION_URLS        = %w[http://clients3.google.com/generate_204].freeze

  def perform!(candidates:, **)
    filtered = candidates.uniq { |p| "#{p[:protocol]}:#{p[:host]}:#{p[:port]}" }
                         .select { |p| p[:host].match?(/\A(\d{1,3}\.){3}\d{1,3}\z/) }
                         .select { |p| VALID_PROTOCOLS.include?(p[:protocol]) }
                         .shuffle

    source_uris = VALIDATION_URLS.filter_map { |u| URI.parse(u) rescue nil }

    valid = log_time('Validation') { validate(filtered, source_uris) }
    log('No valid proxies found', level: :warn, color: :red) if valid.empty?

    self.model = valid
  end

  private

  def validate(candidates, source_uris)
    queue  = Async::Queue.new
    valid  = []
    tested = 0

    candidates.each { |c| queue.enqueue(c) }
    VALIDATION_CONCURRENCY.times { queue.enqueue(nil) }

    fiber_width = VALIDATION_CONCURRENCY.to_s.length
    total       = candidates.size
    started_at  = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Async do
      workers = VALIDATION_CONCURRENCY.times.map do |idx|
        Async do
          fiber_n = (idx + 1).to_s.rjust(fiber_width)
          loop do
            candidate = queue.dequeue
            break unless candidate

            reachable  = valid_proxy?(candidate, source_uris)
            tested    += 1
            elapsed    = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            pct        = (tested * 100.0 / total).round(1)
            status     = reachable ? 'valid' : 'invalid'
            color      = reachable ? :green : :yellow
            valid << candidate if reachable
            log("fiber=#{fiber_n} #{status.ljust(7)} #{candidate[:protocol]}://#{candidate[:host]}:#{candidate[:port]} (valid=#{valid.size} tested=#{tested}/#{total} #{pct}% elapsed=#{elapsed.round(1)}s)", color: color)
          end
        end
      end

      workers.each(&:wait)
    end

    valid
  end

  def valid_proxy?(candidate, source_uris)
    proxy_url = "#{candidate[:protocol]}://#{candidate[:host]}:#{candidate[:port]}"
    client    = ApplyMate::Client::AsyncHttp.new(proxy: proxy_url)
    unconfirmed = source_uris.map(&:to_s)

    VALIDATION_ATTEMPTS.times do |i|
      sleep(0) if i > 0
      url = unconfirmed.sample
      if reachable?(client, url)
        unconfirmed.delete(url)
        return true if unconfirmed.empty?
        sleep(60)
      end
    end

    false
  end

  def reachable?(client, url)
    response = client.get(url)
    (200..399).cover?(response.status)
  rescue ApplyMate::Client::Base::DeadProxyError
    false
  end
end
