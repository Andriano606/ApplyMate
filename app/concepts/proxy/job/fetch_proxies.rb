# frozen_string_literal: true

class Proxy::Job::FetchProxies < ApplicationJob
  queue_as :default

  LIST_URLS = [
    'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/http.txt',
    'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/https.txt'
  ].freeze
  TEST_URL           = 'https://www.google.com'
  TARGET_COUNT       = 100
  VALIDATION_THREADS = 150
  VALIDATION_TIMEOUT = 3

  def perform
    @started_at = Time.current

    parsed = LIST_URLS.flat_map do |url|
      response = Faraday.get(url)
      unless response.success?
        Rails.logger.error "[FetchProxies] Failed to fetch #{url}: HTTP #{response.status}"
        next []
      end
      parse(response.body)
    end

    candidates = parsed.uniq { |p| "#{p[:host]}:#{p[:port]}" }.shuffle
    @total_candidates = candidates.size

    Rails.logger.info "[FetchProxies] Parsed #{candidates.size}/#{parsed.size} unique candidates, target: #{TARGET_COUNT}"

    valid = validate(candidates)

    if valid.empty?
      Rails.logger.warn '[FetchProxies] No valid proxies found'
      return
    end

    now     = Time.current
    records = valid.map { |p| p.merge(active: true, failed_at: nil, created_at: now, updated_at: now) }

    Proxy.upsert_all(records, unique_by: [ :host, :port ], update_only: [ :active, :failed_at ])
    Rails.logger.info "[FetchProxies] Stored #{valid.size} valid proxies"
  end

  private

  def validate(candidates)
    mutex  = Mutex.new
    valid  = []
    pool   = candidates.dup
    tested = 0

    threads = VALIDATION_THREADS.times.map do
      Thread.new do
        loop do
          candidate = mutex.synchronize do
            break if valid.size >= TARGET_COUNT
            pool.pop
          end
          break unless candidate

          if reachable?(candidate)
            mutex.synchronize do
              valid << candidate
              elapsed = (Time.current - @started_at).round(1)
              Rails.logger.info "[FetchProxies] Found #{valid.size}/#{TARGET_COUNT}: #{candidate[:host]}:#{candidate[:port]} | tested #{tested}/#{@total_candidates} | #{elapsed}s"
            end
          end

          mutex.synchronize { tested += 1 }
          break if valid.size >= TARGET_COUNT
        end
      end
    end

    threads.each(&:join)
    Rails.logger.info "[FetchProxies] Tested #{tested} candidates, found #{valid.size} valid"
    valid
  end

  def reachable?(proxy)
    conn = Faraday.new(proxy: "#{proxy[:protocol]}://#{proxy[:host]}:#{proxy[:port]}") do |f|
      f.options.timeout      = VALIDATION_TIMEOUT
      f.options.open_timeout = VALIDATION_TIMEOUT
      f.adapter Faraday.default_adapter
    end

    response = conn.get(TEST_URL)
    response.status < 500
  rescue StandardError
    false
  end

  def parse(body)
    body.lines.filter_map do |line|
      line = line.strip
      next unless line.match?(%r{\Ahttps?://})

      uri = URI.parse(line)
      next unless uri.host.present? && uri.port&.between?(1, 65_535)

      { host: uri.host, port: uri.port, protocol: uri.scheme }
    rescue URI::InvalidURIError
      nil
    end
  end
end
