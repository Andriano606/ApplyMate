# frozen_string_literal: true

require 'async'
require 'async/barrier'
require 'async/semaphore'

class Vacancy::Operation::SyncVacancies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  NoProxiesError = Class.new(StandardError)

  # 32 fibers per phase and source: two sources at once fill ImpersonateHttp::MAX_PROCESSES
  # (64 curl subprocesses on the Pi) exactly. More would only queue for a curl slot — and
  # with MAX_USES / USE_INTERVAL a proxy serves one request a minute, so the pool, not the
  # fiber count, sets the pace.
  WORKERS_PER_SOURCE      = 32
  DESCRIPTION_WORKERS     = 32
  MAX_PAGES               = 2000
  LAST_PAGE_CONFIRMATIONS = 50
  MAX_VACANCY_RETRIES     = 20
  VACANCY_FETCH_BATCH     = 1000
  VACANCY_BUFFER_LIMIT    = 1000

  BULK_UPDATE_DESCRIPTIONS_SQL = <<~SQL.squish
    UPDATE vacancies AS v
    SET description = d.description, description_html = d.description_html
    FROM unnest($1::bigint[], $2::text[], $3::text[]) AS d(id, description, description_html)
    WHERE v.id = d.id
  SQL

  DB_CONCURRENCY          = 5     # max concurrent DB ops (== physical connections) in the run

  HTTP_REQUEST_TIMEOUT    = 25    # whole request (curl --max-time), HTTP_CONNECT_TIMEOUT included
  HTTP_CONNECT_TIMEOUT    = 10

  class DbGateway
    def initialize
      @semaphore = Async::Semaphore.new(DB_CONCURRENCY)
    end

    def call(&block)
      @semaphore.acquire do
        ActiveRecord::Base.connection_pool.with_connection(&block)
      end
    end
  end

  class RequestStats
    ERRORS_IN_SUMMARY = 3

    def initialize
      @requests = 0
      @empty    = 0
      @dead     = 0
      @errors   = Hash.new(0)
      @messages = {}
    end

    def request!
      @requests += 1
    end

    def empty!
      @empty += 1
    end

    def dead!
      @dead += 1
    end

    def error!(error)
      name = error.class.name
      @errors[name] += 1
      @messages[name] ||= error.message.to_s.scrub.truncate(120) # scrub: to_json raises on invalid UTF-8
    end

    def to_h
      {
        requests:        @requests,
        empty_responses: @empty,
        dead_proxies:    @dead,
        failed_requests: @dead + @errors.values.sum,
        errors:          top_errors
      }
    end

    private

    def top_errors
      @errors.max_by(ERRORS_IN_SUMMARY) { |_, count| count }
             .map { |name, count| "#{name}×#{count} (#{@messages[name]})" }.join('; ').presence
    end
  end

  # The proxies of one source for one run, in RAM. ProxyMate hands them out in one session
  # per run and source (`proxy_session`) and never gives the session the same proxy twice.
  # Nothing is reported back to ProxyMate.
  #
  # Use limit: within one round each proxy serves at most MAX_USES requests (failed ones
  # included) with at least USE_INTERVAL seconds between two of them; then it is retired for
  # the round. A proxy that fails as a proxy (DeadProxyError) leaves the pool for the round.
  #
  # Refill: when fewer than MIN_READY proxies are ready now, at most every @refill_interval
  # (REFILL_INTERVAL, doubled up to MAX_REFILL_INTERVAL after a refill that added nothing),
  # one fiber at a time.
  #
  # Rounds: the pool is EMPTY and ProxyMate has nothing new — a refill added no proxy while
  # ProxyMate said `remaining: 0`, or MAX_REFILL_FAILURES refills in a row added none / failed —
  # so the round ends and the next one starts: every proxy the run has had, dead and retired
  # alike, comes back with MAX_USES fresh uses, least recently used first, each still waiting out
  # USE_INTERVAL from its last use. Refills go on as before; whatever new ProxyMate gives joins.
  #
  # Termination — what stops the source when the world stays broken: each round counts its
  # successful uses (`release(proxy)` with ok: true — the request ended without DeadProxyError
  # or an unexpected error; an empty answer counts). MAX_EMPTY_ROUNDS rounds in a row without
  # one, or a seed that brought no proxy at all → @drained → exhausted? → the workers stop and
  # the phase raises NoProxiesError. A run's successes are finite (each one scrapes a page,
  # confirms an end of the listing — at most LAST_PAGE_CONFIRMATIONS per page — or fetches /
  # gives up on a description — at most MAX_VACANCY_RETRIES each; a false empty page the worker
  # only requeues is not a success), so after the last one at most MAX_EMPTY_ROUNDS rounds run.
  # A round itself is finite: each proxy gives it ≤ MAX_USES uses and the session never repeats one.
  class ProxyPool
    include ApplyMate::Logging

    Entry = Struct.new(:proxy, :available_at, :in_use)

    MAX_USES            = 10   # requests per proxy per site in one round
    USE_INTERVAL        = 60   # min seconds between two uses of one proxy on the site
    MIN_READY           = 10   # refill when fewer proxies than this are ready to use now
    SEED_BATCH          = ApplyMate::Client::ProxyMate::MAX_LIMIT # first request: as many as ProxyMate gives
    REFILL_BATCH        = 300  # proxies asked for per refill
    ORDER               = 'stable' # best ProxyMate stability score first
    REFILL_INTERVAL     = 5    # min seconds between refills
    MAX_REFILL_INTERVAL = 60   # backoff cap while ProxyMate has nothing new / is failing
    MAX_REFILL_FAILURES = 3    # refills in a row that leave the pool EMPTY (errors included) before the round ends
    MAX_EMPTY_ROUNDS    = 2    # rounds in a row without a single successful use before the pool is drained

    attr_reader :proxy_session

    def initialize(source, proxy_mate, session_id:, impersonate_targets:)
      scraper_class   = source.scraper.constantize
      client_class    = scraper_class.http_client_class
      clearances      = client_class.supports_cloudflare_clearance?
      @source         = source
      @proxy_mate     = proxy_mate
      @session_id     = session_id
      @proxy_session  = "applymate-#{session_id}-#{source.id}" # ProxyApi::Session::ID_FORMAT
      @query          = {
        site:       scraper_class.proxy_site,
        order:      ORDER,
        protocols:  client_class.supported_proxy_protocols,
        cloudflare: clearances ? 'any' : 'without',
        session_id: @proxy_session
      }
      @query[:impersonate_targets] = impersonate_targets if clearances
      @by_id           = {}             # live entries (idle or in use)
      @idle            = []             # idle entries, sorted by available_at
      @known           = {}             # proxy id => Proxy: every proxy this run has had (brought back each round)
      @uses            = Hash.new(0)    # proxy id => uses this round (kept after it leaves the pool)
      @last_used_at    = {}             # proxy id => monotonic end of its last use (whole run)
      @round           = 1
      @round_successes = 0
      @empty_rounds    = 0              # rounds in a row that ended without a successful use
      @retired         = 0
      @refilling       = false
      @drained         = false
      @fruitless       = 0
      @refill_failures = 0
      @refill_interval = REFILL_INTERVAL
      @last_refill_at  = 0.0
    end

    def seed!
      add_entries(@proxy_mate.proxies(**@query, limit: SEED_BATCH).proxies)
      @last_refill_at = monotonic
      @drained = true if @by_id.empty?
    end

    def size
      @by_id.size
    end

    def with_clearance
      @by_id.each_value.count { |entry| entry.proxy.clearance }
    end

    # A proxy whose interval is over, or nil when none is ready right now.
    def acquire
      maybe_refill

      entry = @idle.first
      return nil unless entry && entry.available_at <= monotonic

      @idle.shift
      entry.in_use = true
      entry.proxy
    end

    # One use is over: the proxy cools down USE_INTERVAL, or retires for the round after
    # MAX_USES. `ok: false` — the request ended in an unexpected (non-proxy) error, or
    # achieved nothing — so it is not a successful use of the round.
    def release(proxy, ok: true)
      entry = checked_out(proxy)
      return unless entry

      @round_successes += 1 if ok
      if use!(entry) >= MAX_USES
        @by_id.delete(proxy.id)
        @retired += 1
      else
        entry.in_use       = false
        entry.available_at = @last_used_at[proxy.id] + USE_INTERVAL
        enqueue(entry)
      end
    end

    # The proxy failed as a proxy (DeadProxyError): the use counts and it leaves the pool
    # until the next round.
    def drop(proxy)
      entry = checked_out(proxy)
      return unless entry

      use!(entry)
      @by_id.delete(proxy.id)
    end

    def exhausted?
      @drained && @by_id.empty?
    end

    # Retirements since the last call and the round the pool is in, for the phase's finished event.
    def take_counts!
      counts = { retired_proxies: @retired, proxy_rounds: @round }
      @retired = 0
      counts
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def checked_out(proxy)
      entry = proxy && @by_id[proxy.id]
      entry if entry&.in_use
    end

    def use!(entry)
      id = entry.proxy.id
      @last_used_at[id] = monotonic
      @uses[id] += 1
    end

    def enqueue(entry)
      index = @idle.bsearch_index { |e| e.available_at > entry.available_at } || @idle.size
      @idle.insert(index, entry)
    end

    def ready_count
      now = monotonic
      @idle.bsearch_index { |e| e.available_at > now } || @idle.size
    end

    def maybe_refill
      return if @refilling || @drained
      return if ready_count >= MIN_READY
      return if monotonic - @last_refill_at < @refill_interval

      refill
    end

    def refill
      @refilling = true
      batch = @proxy_mate.proxies(**@query, limit: REFILL_BATCH)
      @refill_failures = 0
      settle(add_entries(batch.proxies), batch.remaining)
    rescue ApplyMate::Client::ProxyMate::Error => e
      @refill_failures += 1
      settle(0, nil)
      log(event: 'vacancy_sync_proxy_refill_failed', session_id: @session_id, source: @source.name,
          error_class: e.class.name, error: e.message.to_s.scrub.truncate(300),
          failures: @refill_failures, alive: @by_id.size, level: :warn)
    ensure
      @last_refill_at = monotonic
      @refilling = false
    end

    # Backoff and the end of a round (see the class comment). `remaining` is nil after an error.
    # @fruitless counts refills in a row that added nothing (or failed) while the pool was empty.
    def settle(added, remaining)
      @refill_interval = added.zero? ? [ @refill_interval * 2, MAX_REFILL_INTERVAL ].min : REFILL_INTERVAL
      @fruitless       = added.zero? && @by_id.empty? ? @fruitless + 1 : 0
      next_round if @fruitless.positive? && (remaining&.zero? || @fruitless >= MAX_REFILL_FAILURES)
    end

    # Only runs on an empty pool, so no proxy of the ending round is still checked out.
    def next_round
      @empty_rounds = @round_successes.zero? ? @empty_rounds + 1 : 0
      if @empty_rounds >= MAX_EMPTY_ROUNDS
        @drained = true
        return
      end

      @round          += 1
      @round_successes = 0
      @fruitless       = 0
      @uses.clear
      # Oldest last use first (ties: the order the run got them): those come back ready, or
      # ready soonest, and enqueue keeps this order among equal available_at — so the least
      # recently used proxy is taken first.
      proxies = @known.values.each_with_index
                      .sort_by { |proxy, index| [ @last_used_at.fetch(proxy.id, -Float::INFINITY), index ] }
                      .map(&:first)
      add_entries(proxies)
      log(event: 'vacancy_sync_proxy_round_started', session_id: @session_id, source: @source.name,
          round: @round, proxies: proxies.size)
    end

    # A proxy is welcome while it has uses left in this round; it waits out USE_INTERVAL
    # from its last use.
    def add_entries(proxies)
      now = monotonic
      proxies.count do |proxy|
        next false if @by_id.key?(proxy.id) || @uses[proxy.id] >= MAX_USES

        @known[proxy.id] = proxy
        last  = @last_used_at[proxy.id]
        entry = Entry.new(proxy, last ? [ last + USE_INTERVAL, now ].max : now, false)
        @by_id[proxy.id] = entry
        enqueue(entry)
        true
      end
    end
  end

  class VacancyBuffer
    def initialize(db, source)
      @db       = db
      @source   = source
      @buf      = []
      @flushing = false
    end

    def add(structs)
      @buf.concat(structs)
    end

    def maybe_flush
      flush if @buf.size >= VACANCY_BUFFER_LIMIT
    end

    # Persist and clear. `@flushing` guards against a second fiber flushing while
    # the first is suspended inside the DB call (mirrors ProxyPool's `@refilling`).
    def flush
      return if @flushing || @buf.empty?
      @flushing = true

      batch = @buf # yield-free swap: no fiber interleaves between these two lines,
      @buf  = []   # so appends arriving during @db.call land in the fresh buffer.

      begin
        @db.call { persist(batch) }
      rescue StandardError
        # Put the batch back before re-raising: its pages are already in
        # `scraped_pages`, so a dropped batch is silently lost scraping work.
        @buf.concat(batch)
        raise
      end
    ensure
      @flushing = false
    end

    private

    def persist(batch)
      data = batch.compact.uniq(&:external_id)
      return if data.empty?

      # Sources that fetch the description from a detail page in the 2nd pass must NOT
      # let the listing overwrite it — otherwise an existing full description is clobbered
      # by the listing snapshot and the (skip-if-present) detail pass never restores it.
      update_cols = %i[title url company_name company_icon_url]
      update_cols += %i[description description_html] unless @source.scraper.constantize.fetches_description?

      Vacancy.upsert_all(
        data.map(&:to_h),
        unique_by: [ :source_id, :external_id ],
        update_only: update_cols,
        record_timestamps: true
      )

      Vacancy.where(source_id: @source.id, external_id: data.map(&:external_id)).import
    end
  end

  # Every run emits JSON events for Grafana (catalogue: .ai/docs/observability.md):
  # vacancy_sync_started → vacancy_sync_proxy_pool_ready (per source) →
  # vacancy_sync_listing_finished / vacancy_sync_descriptions_finished (per source and
  # phase, also on failure) → vacancy_sync_finished (always, with the run's result).
  def perform!(sources: Source.all, **)
    skip_authorize

    started     = monotonic
    @session_id = (Time.current.to_f * 1000).to_i
    @db         = DbGateway.new
    @proxy_mate = ApplyMate::Client::ProxyMate.new
    @pools      = {}
    @synced     = []
    sources     = sources.to_a

    log(event: 'vacancy_sync_started', session_id: @session_id, started_at_ms: @session_id,
        sources: sources.map(&:name).join(', ')) # a string: Loki's `| json` drops arrays

    @impersonate_targets = impersonate_targets(proxy_mate_meta)

    runnable = sources.select { |source| seed_pool(source) }
    raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if runnable.empty?

    # Pipeline per source: each source runs its own listing → description in one
    # fiber, all sources concurrent. So Dou's descriptions start the moment Dou's
    # listing finishes instead of waiting for every source's listing (Djinni's
    # listing is the slow one) — wall time = max over sources of (listing + desc).
    Async do |top_task|
      runnable.map { |source| top_task.async { sync_source_pipeline(source) } }.each(&:wait)
    end
  rescue StandardError => e
    error = e
    raise
  ensure
    log_run_finished(sources, started, error)
  end

  private

  # GET /api/v1/meta, once per run, before any pool. It may not stop the sync: without it
  # only our default target is asked for.
  def proxy_mate_meta
    @proxy_mate.meta
  rescue ApplyMate::Client::ProxyMate::Error => e
    log(event: 'vacancy_sync_proxy_mate_lookup_failed', session_id: @session_id, lookup: 'meta',
        error_class: e.class.name, error: e.message.to_s.scrub.truncate(300), level: :warn)
    nil
  end

  # Cloudflare tokens are bound to a curl-impersonate target, so ask only for tokens our binary
  # can replay: ProxyMate's targets when it runs the release bin/install-curl-impersonate pins,
  # else (or without meta) just our default target.
  def impersonate_targets(meta)
    client  = ApplyMate::Client::ImpersonateHttp
    default = [ client::DEFAULT_IMPERSONATE ]
    return default unless meta
    return meta.curl_targets if meta.curl_release == client::RELEASE && meta.curl_targets.any?

    log(event: 'vacancy_sync_curl_impersonate_mismatch', session_id: @session_id, release: client::RELEASE,
        proxy_mate_release: meta.curl_release, targets: default.join(', '), level: :warn)
    default
  end

  # One proxy pool per source, seeded from ProxyMate's list for THAT site — ProxyMate
  # checks every proxy on every site separately (dou blocks proxies djinni allows and
  # vice-versa), so a shared pool would starve whichever source it wasn't checked for.
  # A source whose pool comes back empty — or whose ProxyMate request fails (not
  # configured, unreachable, 401, unknown site) — is reported and skipped, not fatal: the
  # other sources still sync, and the run ends `partial` / `failed`. Returns whether it can run.
  def seed_pool(source)
    pool = ProxyPool.new(source, @proxy_mate, session_id: @session_id, impersonate_targets: @impersonate_targets)
    begin
      pool.seed!
    rescue ApplyMate::Client::ProxyMate::Error => e
      error = e
    end

    level = if error then :error elsif pool.size.zero? then :warn else :info end
    log(event: 'vacancy_sync_proxy_pool_ready', session_id: @session_id, source: source.name,
        alive: pool.size, with_clearance: pool.with_clearance, **error_fields(error), level: level)
    return false if pool.size.zero?

    @pools[source.id] = pool
    true
  end

  # A source's listing → description pipeline. A failure is already reported by the
  # phase's summary event; it is contained here so the other sources keep syncing.
  def sync_source_pipeline(source)
    sync_source(source)
    # Sources whose listing already carries the description (Djinni) have no second
    # pass — there is no detail page left to visit.
    fetch_description_for_source(source) if source.scraper.constantize.fetches_description?
    @synced << source.name
  rescue StandardError
    nil
  end

  # Times one phase of a source and always emits its summary event — also when the
  # phase raises, so a failed source shows up in Grafana with its error instead of
  # silently missing from the charts. The block fills `summary` with phase totals and
  # counts its requests in `stats`.
  def log_phase(event, source)
    pool    = @pools[source.id]
    summary = {}
    stats   = RequestStats.new
    started = monotonic
    yield summary, stats
  rescue StandardError => e
    error = e
    raise
  ensure
    log(event: event, session_id: @session_id, source: source.name,
        result: error ? 'failed' : 'ok', duration_s: (monotonic - started).round(3),
        **summary, **stats.to_h, **pool.take_counts!, **error_fields(error), level: error ? :error : :info)
  end

  def log_run_finished(sources, started, error)
    failed = sources.size - @synced.size
    result = if error || @synced.empty?
      'failed'
    elsif failed.positive?
      'partial'
    else
      'ok'
    end

    log(event: 'vacancy_sync_finished', session_id: @session_id, result: result,
        duration_s: (monotonic - started).round(3), sources_ok: @synced.size, sources_failed: failed,
        **error_fields(error), level: result == 'ok' ? :info : :error)
  end

  def error_fields(error)
    return {} unless error

    # scrub: to_json raises on invalid UTF-8, and this runs in an ensure — it would mask the real error.
    { error_class: error.class.name, error: error.message.to_s.scrub.truncate(300), error_at: error.backtrace&.first }
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def sync_source(source)
    pool = @pools[source.id]
    log_phase('vacancy_sync_listing_finished', source) do |summary, stats|
      count_before  = with_db { source.vacancies.count }
      external_ids  = Concurrent::Array.new
      pages_queue   = (1..MAX_PAGES).to_a
      last_page     = { counts: Hash.new(0), boundary: nil }
      scraped_pages = Set.new
      stop          = [ false ]
      buffer        = VacancyBuffer.new(@db, source)
      barrier       = Async::Barrier.new

      WORKERS_PER_SOURCE.times do
        barrier.async { scrape_pages(source, pages_queue, external_ids, last_page, scraped_pages, stop, buffer, pool, stats) }
      end

      begin
        barrier.wait
      ensure
        # A worker that raised (BinaryError) must not leave its siblings running (barrier.stop),
        # and the buffer — up to VACANCY_BUFFER_LIMIT already-scraped vacancies — is drained
        # BEFORE the source is judged failed: raising first threw that work away.
        barrier.stop
        buffer.flush
      end

      # external_ids could have duplicates
      active_ids = external_ids.uniq
      summary.merge!(pages: scraped_pages.size, vacancies: active_ids.size)

      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]

      stale = clean_old_vacancies(source, active_ids)
      Vacancy::Operation::CountBySource.expire!

      # Single writer per source (the job's limits_concurrency), so the row-count delta
      # is exact: total now = before + new − stale.
      total = with_db { source.vacancies.count }
      summary.merge!(new_vacancies: total - count_before + stale, stale_deleted: stale, vacancies_total: total)
    end
  end

  def fetch_description_for_source(source)
    pool = @pools[source.id]
    log_phase('vacancy_sync_descriptions_finished', source) do |summary, stats|
      total        = 0
      done         = [ 0 ]
      skipped      = [ 0 ]
      stop         = [ false ]
      retry_counts = Hash.new(0)
      last_id      = 0

      loop do
        break if stop[0]

        # Skip vacancies that already have a description — only fetch the ones still missing
        # one (new this run + any whose previous detail fetch failed). Huge win for Dou,
        # whose detail pass otherwise re-fetches every vacancy through rate-limited proxies.
        # Keyed on description_html (not description): rows scraped before descriptions were
        # stored as markup have text but no markup, and this is what backfills them.
        scope = source.vacancies.select(:id, :external_id, :url)
                      .where('vacancies.id > ?', last_id)
                      .where(description_html: [ nil, '' ])
        vacancies_queue = with_db { scope.order(:id).limit(VACANCY_FETCH_BATCH).to_a }
        break if vacancies_queue.empty?

        last_id = vacancies_queue.last.id
        total  += vacancies_queue.size
        updates = Concurrent::Array.new
        barrier = Async::Barrier.new

        DESCRIPTION_WORKERS.times do
          barrier.async { fetch_description_worker(source, vacancies_queue, done, updates, retry_counts, stop, skipped, pool, stats) }
        end

        begin
          barrier.wait
        ensure
          # Siblings of a worker that raised are stopped, and descriptions already fetched
          # in this batch are still written — one bulk write per cursor-batch.
          barrier.stop
          if updates.any?
            rows = updates.to_a
            with_db do
              bulk_update_descriptions(rows)
              Vacancy.where(id: rows.map { |r| r[:id] }).import
            end
          end
        end
      end

      summary.merge!(missing: total, fetched: done[0], gave_up: skipped[0],
                     max_attempts: retry_counts.values.max || 0)

      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]
    end
  end

  def fetch_description_worker(source, vacancies_queue, done, updates, retry_counts, stop, skipped, pool, stats)
    scraper_class = source.scraper.constantize

    loop do
      break if stop[0]

      begin
        proxy   = nil
        vacancy = vacancies_queue.shift
        break unless vacancy

        proxy = pool.acquire
        unless proxy
          if pool.exhausted?
            stop[0] = true
            vacancies_queue.unshift(vacancy)
            break
          end
          vacancies_queue.unshift(vacancy)
          sleep(0.2)
          next
        end

        stats.request!
        scraper = build_scraper(scraper_class, source, proxy)
        html    = scraper.fetch_description(vacancy.url)

        if html.present?
          # Store the markup as the source wrote it and derive the plain-text column
          # from that same string, so the two can never describe different content.
          updates << { id: vacancy.id, description_html: html, description: scraper_class.to_plain_text(html) }
          done[0] += 1
        else
          stats.empty!
          count = retry_counts[vacancy.id] += 1
          if count >= MAX_VACANCY_RETRIES
            skipped[0] += 1
          else
            vacancies_queue.unshift(vacancy)
          end
        end
      rescue ApplyMate::Scraper::Base::DeadProxyError
        stats.dead!
        pool.drop(proxy)
        proxy = nil
        vacancies_queue.unshift(vacancy)
        retry
      rescue ApplyMate::Client::ImpersonateHttp::BinaryError
        stop[0] = true
        pool.release(proxy, ok: false)
        proxy = nil
        vacancies_queue.unshift(vacancy)
        raise # the host cannot run curl at all — retrying would only burn the pool
      rescue StandardError => e
        stats.error!(e)
        pool.release(proxy, ok: false)
        proxy = nil
        vacancies_queue.unshift(vacancy)
        retry
      ensure
        pool.release(proxy)
        proxy = nil
      end
    end
  end

  def break_fiber_condition(scraped_pages, last_page, stop, page)
    return true if page.nil?
    return true if stop[0]
    return false unless last_page[:boundary]

    last_page_num = last_page[:boundary] - 1
    scraped_pages.max == last_page_num && scraped_pages.size == last_page_num
  end

  def next_fiber_condition(page, scraped_pages, last_page)
    true if (last_page[:boundary] && page >= last_page[:boundary]) ||
                   (scraped_pages.any? && scraped_pages.include?(page))
  end

  def scrape_pages(source, pages_queue, external_ids, last_page, scraped_pages, stop, buffer, pool, stats)
    scraper_class = source.scraper.constantize

    loop do
      begin
        proxy = nil

        page = pages_queue.shift

        break if break_fiber_condition(scraped_pages, last_page, stop, page)
        next if next_fiber_condition(page, scraped_pages, last_page)

        proxy = pool.acquire
        unless proxy
          if pool.exhausted?
            stop[0] = true
            pages_queue.unshift(page)
            break
          end
          pages_queue.unshift(page)
          sleep(0.2)
          next
        end

        stats.request!
        scraper = build_scraper(scraper_class, source, proxy)
        listing = scraper.fetch_listing(page: page)

        if listing&.any?
          scraped_pages << page
          last_page[:counts].delete_if { |p, _| p <= scraped_pages.max }
          buffer.add(listing)
          external_ids.concat(listing.map(&:external_id))
          buffer.maybe_flush
        else
          stats.empty!
          if scraped_pages.empty? || (scraped_pages.any? && page > scraped_pages.max)
            last_page[:counts][page] += 1
            count = last_page[:counts][page]

            if count >= LAST_PAGE_CONFIRMATIONS
              last_page[:boundary] = [ last_page[:boundary], page ].compact.min
              pages_queue.delete_if { |a| a >= last_page[:boundary] || scraped_pages.include?(a) }
            elsif count == 1
              LAST_PAGE_CONFIRMATIONS.times { pages_queue.unshift(page) }
            end
          else
            # A false empty below the scraped range: requeued without limit, so it is not a
            # successful use — a page that keeps coming back empty must not keep the pool's
            # rounds going forever (ProxyPool's termination rule).
            pool.release(proxy, ok: false)
            proxy = nil
            pages_queue.unshift(page)
          end
        end
      rescue ApplyMate::Scraper::Base::DeadProxyError
        stats.dead!
        pool.drop(proxy)
        proxy = nil
        pages_queue.unshift(page)
        retry
      rescue ApplyMate::Client::ImpersonateHttp::BinaryError
        stop[0] = true
        pool.release(proxy, ok: false)
        proxy = nil
        pages_queue.unshift(page)
        raise # the host cannot run curl at all — retrying would only burn the pool
      rescue StandardError => e
        stats.error!(e)
        pool.release(proxy, ok: false)
        proxy = nil
        pages_queue.unshift(page)
        retry
      ensure
        pool.release(proxy)
        proxy = nil
      end
    end
  end

  # One client + scraper per proxied request. `proxy` is an ApplyMate::Client::ProxyMate::Proxy;
  # its Cloudflare clearance (if any) travels with it into the client.
  def build_scraper(scraper_class, source, proxy)
    client = scraper_class.http_client_class.new(proxy: proxy.url, clearance: proxy.clearance,
                                                 request_timeout: HTTP_REQUEST_TIMEOUT, connect_timeout: HTTP_CONNECT_TIMEOUT)
    scraper_class.new(source, client)
  end

  def with_db(&block)
    @db.call(&block)
  end

  # Removes this source's vacancies the listing no longer shows; returns how many.
  # Skipped when nothing was scraped — an empty listing must not wipe the source.
  def clean_old_vacancies(source, active_ids)
    return 0 if active_ids.empty?

    with_db { source.vacancies.where.not(external_id: active_ids).destroy_all.size }
  end

  # Bulk-update descriptions for a cursor-batch in one statement. A pure UPDATE
  # (not upsert_all) — the rows already exist, and upsert's INSERT path would
  # violate NOT NULL on the id+description-only tuples.
  #
  # The batch travels as three array binds unnested into rows, not as an interpolated
  # `VALUES (…), (…)` list. The SQL text is then constant whatever the batch size, so
  # Postgres parses one statement instead of a new one per batch — and there is no
  # string-built SQL left for a future edit (or a static analyser) to get wrong.
  def bulk_update_descriptions(rows)
    Vacancy.connection.exec_update(BULK_UPDATE_DESCRIPTIONS_SQL, 'bulk_update_descriptions', [
      array_bind(rows.map { |r| r[:id] },               ActiveRecord::Type::BigInteger.new),
      array_bind(rows.map { |r| r[:description] },      ActiveRecord::Type::Text.new),
      array_bind(rows.map { |r| r[:description_html] }, ActiveRecord::Type::Text.new)
    ])
  end

  def array_bind(values, subtype)
    ActiveRecord::Relation::QueryAttribute.new(
      nil, values, ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array.new(subtype, ',')
    )
  end
end
