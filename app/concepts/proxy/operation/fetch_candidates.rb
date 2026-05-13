# frozen_string_literal: true

require 'async'
require 'set'

class Proxy::Operation::FetchCandidates < ApplyMate::Operation::Base
  include ApplyMate::Logging

  SCHEMED_PROXY_URI  = /\A(socks5h|socks5a|socks5|https?)\z/i.freeze
  FETCH_CONCURRENCY  = Integer(ENV.fetch('FETCH_PROXIES_FETCH_CONCURRENCY', '50'))
  FETCH_OPEN_TIMEOUT = 10
  FETCH_READ_TIMEOUT = 60
  FETCH_RETRIES      = 2

  LIST_URLS = [
    'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/socks5.txt',
    'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt',
    'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/https/data.txt',
    'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/https.txt',
    'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/http/data.txt',
    'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/http.txt'
  ].freeze

  def perform!(**)
    proxies = log_time('Fetch') { fetch_from_sources }
    unique  = proxies.uniq { |p| [ p[:protocol], p[:host], p[:port] ] }.size
    log("Parsed #{unique}/#{proxies.size} unique candidates")
    self.model = proxies
  end

  private

  def fetch_from_sources
    fetch_queue = Async::Queue.new
    visited     = Set.new
    proxies     = []
    pending     = 0

    enqueue = ->(url) {
      return if url.blank? || visited.include?(url)
      visited.add(url)
      pending += 1
      fetch_queue.enqueue(url)
    }

    LIST_URLS.each { |url| enqueue.call(url) }

    Async do
      FETCH_CONCURRENCY.times.map do
        Async do
          loop do
            url = fetch_queue.dequeue
            break unless url

            body     = fetch_body(url)
            new_urls = []

            if body
              ingest_body(body, default_protocol: infer_protocol(url)) do |entry|
                if entry[:type] == :catalog
                  new_urls << entry[:url].to_s
                elsif entry[:host].present? && entry[:port].present? && entry[:protocol].present?
                  proxies << entry
                end
              end
            end

            # Increment pending for children BEFORE decrementing for self so it never
            # hits zero while work still exists.
            new_urls.each { |u| enqueue.call(u) }
            pending -= 1

            FETCH_CONCURRENCY.times { fetch_queue.enqueue(nil) } if pending.zero?
          end
        end
      end.each(&:wait)
    end

    proxies
  end

  def fetch_body(url)
    FETCH_RETRIES.times do |attempt|
      body = try_fetch(url)
      return body if body
      log("Retry #{attempt + 1}/#{FETCH_RETRIES} for #{url}", color: :yellow)
    end
    try_fetch(url)
  end

  def try_fetch(url)
    response = http_client.get(url)
    return response.body if response.success?
    log("HTTP #{response.status} fetching #{url}", level: :warn, color: :red)
    nil
  rescue StandardError => e
    log("#{e.class} fetching #{url}: #{e.message}", level: :warn, color: :red)
    nil
  end

  # Faraday's net_http adapter uses Net::HTTP → TCPSocket, which is fiber-aware
  # under Ruby 3's Async scheduler. Native timeouts (not Async::Task#with_timeout)
  # are used so that a slow download doesn't leave the connection in a broken state.
  def http_client
    @http_client ||= Faraday.new do |f|
      f.options.open_timeout = FETCH_OPEN_TIMEOUT
      f.options.timeout      = FETCH_READ_TIMEOUT
      f.use Faraday::FollowRedirects::Middleware, limit: 5
      f.adapter Faraday.default_adapter
    end
  end

  def infer_protocol(url)
    u    = url.to_s.downcase
    path = begin
             URI.parse(url).path.downcase
           rescue URI::InvalidURIError
             u
           end

    return 'socks5h' if path.include?('socks5a') || u.include?('socks5a')
    return 'socks5'  if path.include?('socks5')  || u.include?('socks5')
    # Do not use `include?('https')` — every URL is https://…
    # "https.txt" means the proxy forwards HTTPS traffic, not that it speaks TLS itself — store as http.
    return 'http' if path.end_with?('/https.txt') || %r{/https\.txt(\?|\z)}.match?(path)
    return 'http' if path.end_with?('/http.txt')  || %r{/http\.txt(\?|\z)}.match?(path)

    'http'
  end

  def ingest_body(body, default_protocol:)
    body.each_line do |raw|
      parse_line(raw, default_protocol: default_protocol) { |parsed| yield parsed }
    end
  end

  def parse_line(raw, default_protocol:)
    line = raw.to_s.split(',,').first.to_s.strip
    return if line.empty? || line.start_with?('#')

    if catalog_url?(line)
      yield({ type: :catalog, url: line })
      return
    end

    h = parse_endpoint(line, default_protocol: default_protocol)
    yield(h) if h
  end

  # gfpcom `sources/*.txt` files are mostly links to other Git-hosted proxy dumps, not host:port lines.
  def catalog_url?(line)
    return false unless line.match?(%r{\Ahttps?://}i)

    uri = URI.parse(line)
    return false unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    host = uri.host.to_s.downcase
    return true if host.end_with?('githubusercontent.com', 'github.com', 'gist.githubusercontent.com')
    return true if host.include?('gitlab.com') || host.include?('bitbucket.org')

    path = uri.path.to_s
    return true if path.match?(%r{/raw/}i) && path.match?(/\.(txt|csv)\z/i)

    # Plain https://cdn.example/path/list.txt (default port) is a dump URL, not a proxy on :443.
    if uri.scheme&.match?(/\Ahttps?\z/i) && path.present? && path != '/' && !host.match?(/\A(?:\d{1,3}\.){3}\d{1,3}\z/)
      default = (uri.scheme == 'https' ? 443 : 80)
      return true if uri.port == default
    end

    false
  rescue URI::InvalidURIError
    false
  end

  def parse_endpoint(line, default_protocol:)
    trimmed = line.strip
    begin
      uri = URI.parse(trimmed)
      if uri.scheme&.match?(SCHEMED_PROXY_URI) && uri.host.present? && uri.port&.between?(1, 65_535)
        return { host: uri.host, port: uri.port, protocol: normalize_scheme(uri.scheme) }
      end
    rescue URI::InvalidURIError
      # fall through to host:port
    end

    return unless trimmed.match?(
      /\A(?<host>(?:\d{1,3}\.){3}\d{1,3}|[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?):(?<port>\d{1,5})\z/i
    )

    host = Regexp.last_match(:host)
    port = Regexp.last_match(:port).to_i
    return unless port.between?(1, 65_535)

    { host: host, port: port, protocol: default_protocol }
  end

  def normalize_scheme(scheme)
    case scheme.to_s.downcase
    when 'socks5a' then 'socks5h'
    when 'https'   then 'http'  # proxy speaks plain HTTP CONNECT, not TLS
    else scheme.to_s.downcase
    end
  end
end
