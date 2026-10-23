# frozen_string_literal: true

require 'async'
require 'async/barrier'
require 'async/semaphore'
require 'kernel/sync'
require 'set'

# Downloads the public proxy lists and streams the parsed candidates to `on_batch` in
# slices of BATCH_SIZE, so neither Ruby nor Postgres ever holds a whole dump at once.
#
# The three gfpcom dumps alone are ~560–600k lines each (~1.75M together). Collecting all
# of them into one array and inserting it in a single statement ran the Raspberry Pi out of
# memory every night and froze the whole host. Every run is now bounded:
#
#   max_per_list   — each list contributes a random sample of at most ~this many entries
#                    (Bernoulli, p = max_per_list / lines). Taking the first N instead would
#                    pick the same alphabetically-first IPs of a sorted dump every night.
#   max_candidates — hard cap on unique candidates per run; once hit, the remaining lines
#                    and lists are skipped.
#   max_depth      — levels of catalog links (a list linking to other lists) followed.
#   max_urls       — lists fetched in total, roots included.
#
# Model: the number of unique candidates handed to `on_batch`.
class Proxy::Operation::FetchCandidates < ApplyMate::Operation::Base
  include ApplyMate::Logging

  SCHEMED_PROXY_URI  = /\A(socks5h|socks5a|socks5|https?)\z/i.freeze
  # Each fetching fiber holds a whole list body (~15 MB for a gfpcom dump) while parsing,
  # so this bounds peak memory as well as sockets. One per root list.
  FETCH_CONCURRENCY  = Integer(ENV.fetch('FETCH_PROXIES_FETCH_CONCURRENCY', '6'))
  FETCH_OPEN_TIMEOUT = 10
  FETCH_READ_TIMEOUT = 60
  FETCH_RETRIES      = 2
  # Proxy::Job::Validate probes ~2000 proxies every 5 minutes (~576k/day), so a 200k
  # nightly intake is fully probed within the day.
  MAX_CANDIDATES     = Integer(ENV.fetch('FETCH_PROXIES_MAX_CANDIDATES', '200000'))
  MAX_PER_LIST       = Integer(ENV.fetch('FETCH_PROXIES_MAX_PER_LIST', '50000'))
  MAX_DEPTH          = Integer(ENV.fetch('FETCH_PROXIES_MAX_DEPTH', '1'))
  MAX_URLS           = Integer(ENV.fetch('FETCH_PROXIES_MAX_URLS', '50'))
  BATCH_SIZE         = 5_000
  # Parsing a 600k-line dump is CPU-bound; hand the reactor back periodically so the other
  # lists' downloads are not starved into read timeouts.
  YIELD_EVERY_LINES  = 10_000

  LIST_URLS = [
    'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/socks5.txt',
    'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/socks5/data.txt',
    'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/https/data.txt',
    'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/https.txt',
    'https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/http/data.txt',
    'https://raw.githubusercontent.com/wiki/gfpcom/free-proxy-list/lists/http.txt'
  ].freeze

  def perform!(on_batch:, urls: LIST_URLS, max_candidates: MAX_CANDIDATES, max_per_list: MAX_PER_LIST,
               max_depth: MAX_DEPTH, max_urls: MAX_URLS, **)
    @on_batch       = on_batch
    @max_candidates = max_candidates
    @max_per_list   = max_per_list
    @max_depth      = max_depth
    @max_urls       = max_urls
    @seen           = Set.new # "protocol://host:port" of every candidate handed out this run
    @visited        = Set.new
    @buffer         = []

    log('Fetch') { crawl(urls) }
    log("Collected #{@seen.size} unique candidates from #{@visited.size} lists")
    self.model = @seen.size
  end

  private

  def crawl(urls)
    Sync do
      @barrier   = Async::Barrier.new
      @semaphore = Async::Semaphore.new(FETCH_CONCURRENCY)
      # One writer at a time: under fiber isolation every fiber in a query holds its own
      # pooled connection, so this keeps the run to a single extra connection.
      @db        = Async::Semaphore.new(1)

      urls.each { |url| schedule(url, depth: 0) }

      begin
        # Lists scheduled while waiting (catalog links) join the barrier, so this returns
        # only once every list is done. A failed list (DB error) re-raises here.
        @barrier.wait
      ensure
        @barrier.cancel
        flush # batches parsed before a failure are still persisted
      end
    end
  end

  # Spawns the fetch without waiting for a slot: a list scheduling its catalog children
  # while holding a slot would otherwise deadlock once every slot did the same.
  def schedule(url, depth:)
    return if url.blank? || @visited.include?(url) || @visited.size >= @max_urls

    @visited.add(url)
    @barrier.async { @semaphore.acquire { ingest_list(url, depth) } }
  end

  def ingest_list(url, depth)
    return if full?

    body = fetch_body(url)
    return unless body

    sample   = [ @max_per_list.fdiv(body.count("\n") + 1), 1.0 ].min
    protocol = infer_protocol(url)
    task     = Async::Task.current

    body.each_line.with_index(1) do |raw, i|
      break if full?
      task.yield if (i % YIELD_EVERY_LINES).zero?

      parse_line(raw, default_protocol: protocol) do |entry|
        if entry[:type] == :catalog
          schedule(entry[:url].to_s, depth: depth + 1) if depth < @max_depth
        elsif rand < sample
          add(entry)
        end
      end
    end
  end

  def full?
    @seen.size >= @max_candidates
  end

  def add(entry)
    return unless @seen.add?("#{entry[:protocol]}://#{entry[:host]}:#{entry[:port]}")

    @buffer << entry
    flush if @buffer.size >= BATCH_SIZE
  end

  # The buffer is swapped yield-free before the write, so entries parsed by other fibers
  # meanwhile land in the fresh one. A write that does not complete — it raised, or the
  # fiber was cancelled after a sibling failed (Async::Cancel is not a StandardError) —
  # puts its batch back so the final flush in `crawl` retries it.
  def flush
    return if @buffer.empty?

    batch   = @buffer
    @buffer = []
    written = false
    @db.acquire do
      ActiveRecord::Base.connection_pool.with_connection { @on_batch.call(batch) }
      written = true
    end
  ensure
    @buffer.concat(batch) if batch && !written
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
    return nil if response.nil?
    return response.body if (200..299).cover?(response.status)
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

    # `match`, not `match?` — the latter does not set the captures read below.
    match = trimmed.match(
      /\A(?<host>(?:\d{1,3}\.){3}\d{1,3}|[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?):(?<port>\d{1,5})\z/i
    )
    return unless match

    port = match[:port].to_i
    return unless port.between?(1, 65_535)

    { host: match[:host], port: port, protocol: default_protocol }
  end

  def normalize_scheme(scheme)
    case scheme.to_s.downcase
    when 'socks5a' then 'socks5h'
    when 'https'   then 'http'  # proxy speaks plain HTTP CONNECT, not TLS
    else scheme.to_s.downcase
    end
  end
end
