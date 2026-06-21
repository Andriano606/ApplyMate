# frozen_string_literal: true

require 'async'
require 'async/barrier'
require 'async/semaphore'
require 'kernel/sync'

# Probes a batch of proxies against EACH source and records the result per
# (proxy, source) in proxy_source_stats, so the per-source usable pool grows over
# time. A proxy alive for one site is often blocked on another, so liveness is
# tracked per source — SyncVacancies then seeds each source's pool from its own
# working proxies.
#
#   reachable for source → success_count += 1 (for that source)  → "working" there
#   not reachable        → fail_count += 1                       → drops out there
#
# Run recurringly (Proxy::Job::Validate): it churns through proxies not yet tested
# for the sources, a batch at a time.
class Proxy::Operation::Validate < ApplyMate::Operation::Base
  # Sized to run every 5 minutes on a Raspberry Pi 5 (4 cores, 16 GB) without heavy load.
  # The probes are I/O-bound; the only real cost is concurrent TLS handshakes, so ~100 in
  # flight keeps CPU/FDs light. DEFAULT_LIMIT bounds one run to a few minutes (each batch
  # is probed against every source), well inside the 5-minute window. Bump CONCURRENCY via
  # ENV on a beefier host.
  CONCURRENCY     = ENV.fetch('PROXY_VALIDATE_CONCURRENCY', 100).to_i
  REQUEST_TIMEOUT = 10
  CONNECT_TIMEOUT = 5
  DEFAULT_LIMIT   = 2000

  # scope:
  #   :untested (default) — grow: proxies with no per-source stats yet
  #   :working            — refresh: proxies that work for at least one source
  def perform!(limit: DEFAULT_LIMIT, scope: :untested, sources: nil, **)
    skip_authorize

    sources    = Array(sources).presence || Source.all.to_a
    candidates = candidate_scope(scope).limit(limit).to_a
    return self.model = { validated: 0, alive: {} } if candidates.empty? || sources.empty?

    alive_by_source = {}
    Sync do
      sources.each { |source| alive_by_source[source.id] = probe_alive(candidates, target_for(source)) }
    end

    record(candidates, sources, alive_by_source)
    self.model = { validated: candidates.size, alive: alive_by_source.transform_values(&:size) }
  end

  private

  def candidate_scope(scope)
    case scope
    when :working
      Proxy.where(id: ProxySourceStat.working.select(:proxy_id)).order(created_at: :desc)
    else
      # NOT EXISTS (anti-join) — NOT IN (subquery) does a ~1M-row sequential scan that
      # pegs Postgres for minutes and keeps running even after the job is killed.
      Proxy.where('NOT EXISTS (SELECT 1 FROM proxy_source_stats WHERE proxy_source_stats.proxy_id = proxies.id)')
           .order(created_at: :desc)
    end
  end

  def target_for(source)
    source.scraper.constantize.validation_url(source)
  end

  # Returns the set of proxy ids reachable for this target. Probed with the fast
  # pure-Ruby AsyncHttp (no curl subprocess) for ALL sources — validation only needs
  # to learn the proxy is alive and reaches the site; scraping then uses each source's
  # real client (Cloudflare sources scrape via ImpersonateHttp).
  def probe_alive(candidates, url)
    alive     = Concurrent::Array.new
    barrier   = Async::Barrier.new
    semaphore = Async::Semaphore.new(CONCURRENCY, parent: barrier)
    candidates.each do |proxy|
      semaphore.async { alive << proxy.id if reachable?(proxy, url) }
    end
    barrier.wait
    alive.to_set
  end

  # Reachable = the proxy actually reached the site. Accept:
  #   • 2xx/3xx — the real page loaded;
  #   • 403 Cloudflare challenge ("Just a moment…") — the proxy IS alive and reached
  #     the site; only OpenSSL's TLS fingerprint got challenged. At scrape time the
  #     Cloudflare source uses ImpersonateHttp (Chrome TLS), which clears that
  #     challenge — so the proxy is genuinely usable. A plain 403 with no challenge
  #     markers (e.g. a 1020 IP firewall block) is NOT accepted.
  def reachable?(proxy, url)
    client = ApplyMate::Client::AsyncHttp.new(proxy: proxy.url, request_timeout: REQUEST_TIMEOUT, connect_timeout: CONNECT_TIMEOUT)
    client.get(url)&.alive_or_cf_challenge? || false
  rescue StandardError
    false
  end

  def record(candidates, sources, alive_by_source)
    now      = Time.current
    existing = ProxySourceStat
               .where(proxy_id: candidates.map(&:id), source_id: sources.map(&:id))
               .index_by { |stat| [ stat.proxy_id, stat.source_id ] }

    rows = candidates.flat_map do |proxy|
      sources.map do |source|
        stat  = existing[[ proxy.id, source.id ]]
        alive = alive_by_source[source.id].include?(proxy.id)
        succ  = (stat&.success_count || 0) + (alive ? 1 : 0)
        fail  = (stat&.fail_count || 0) + (alive ? 0 : 1)
        {
          proxy_id:      proxy.id,
          source_id:     source.id,
          success_count: succ,
          fail_count:    fail,
          failed_at:     alive ? stat&.failed_at : now,
          reliability:   ProxySourceStat.reliability_for(succ, fail)
        }
      end
    end

    ProxySourceStat.upsert_all(rows, unique_by: %i[proxy_id source_id],
                                     update_only: %i[success_count fail_count failed_at reliability],
                                     record_timestamps: true)
  end
end
