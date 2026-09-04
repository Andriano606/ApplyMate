# frozen_string_literal: true

require 'async'
require 'async/barrier'
require 'async/semaphore'
require 'kernel/sync'

class Vacancy::Operation::SyncVacancies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  NoProxiesError = Class.new(StandardError)

  WORKERS_PER_SOURCE      = 100
  DESCRIPTION_WORKERS     = 140   # bounded by live-proxy count × burst throughput
  MAX_PAGES               = 2000
  LAST_PAGE_CONFIRMATIONS = 50
  MAX_VACANCY_RETRIES     = 20
  VACANCY_FETCH_BATCH     = 1000
  VACANCY_BUFFER_LIMIT    = 1000

  # Constant SQL for bulk_update_descriptions — the batch arrives as three array binds.
  BULK_UPDATE_DESCRIPTIONS_SQL = <<~SQL.squish
    UPDATE vacancies AS v
    SET description = d.description, description_html = d.description_html
    FROM unnest($1::bigint[], $2::text[], $3::text[]) AS d(id, description, description_html)
    WHERE v.id = d.id
  SQL

  DB_CONCURRENCY          = 5     # max concurrent DB ops (== physical connections) in the run

  # Timeouts for sync. Not too aggressive: of ~964k proxies only a few hundred ever
  # work, and they are often slow-but-alive — a 3s connect killed them. Fail dead
  # proxies in reasonable time without dropping the scarce good ones.
  HTTP_REQUEST_TIMEOUT    = 10
  HTTP_CONNECT_TIMEOUT    = 5

  # Pre-flight proxy validation. Of the few hundred ever-proven proxies, only a few
  # dozen are alive at any moment; culling the dead ones DURING scraping is what
  # wastes the run. So probe the proven proxies once at startup (~seconds) and seed
  # the pool with only the live ones — almost every later acquire then hits a worker.
  VALIDATE_PROVEN_ON_START = true
  VALIDATION_CONCURRENCY   = 250  # concurrent live-probes (fast AsyncHttp) when seeding/refilling

  # Bounds DB access in the run to a small pool of connections.
  #
  # Under `IsolatedExecutionState.isolation_level = :fiber`, the `pg` gem yields
  # while waiting on Postgres, so N fibers running queries concurrently each hold
  # their own connection — which is what previously forced a 300-connection pool
  # and exhausted Postgres' 100-slot server limit.
  #
  # `Async::Semaphore.new(DB_CONCURRENCY)` caps concurrent DB ops at a handful, so
  # the pool opens at most that many physical connections. A small pool (not 1) lets
  # a slow proxy `refill` run without blocking quick reads / per-batch upserts.
  # Safe: this runs in the Solid Queue worker process (separate from Puma), well
  # under Postgres' connection limit.
  #
  # Non-reentrant: no `with_db` block may nest another `with_db` or run a scraper
  # HTTP request (those stay outside the gateway). ES `.import` (a SELECT on the
  # already-held connection + an HTTP bulk to Elasticsearch) does not re-enter the
  # semaphore, so it is safe.
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

  # In-memory rotating proxy pool shared by every fiber in both phases.
  #
  # Replaces the previous per-request `Proxy.transaction { FOR UPDATE SKIP LOCKED }`
  # acquisition: proxies are loaded from the DB in batches, rotated entirely in
  # memory (respecting the same "one proxy at most once per 5s" rule via an
  # in-memory cooldown), and the DB is touched only to refill the pool and to
  # flush buffered success/fail counters in a single bulk upsert.
  #
  # Fibers are single-threaded (Async), so the bookkeeping needs no mutex; the only
  # suspension points are the DB calls inside `refill`/`flush!`, guarded by
  # `@refilling` so a single fiber performs the reload while the others keep going.
  #
  # Assumes a single SyncVacancies run at a time (enforced by the job's
  # `limits_concurrency`) — the pool, not the DB, owns the cooldown rule.
  class ProxyPool
    Entry = Struct.new(:proxy, :available_at, :in_use, :burst)

    # Burst model (per-site, since each Source has its OWN pool): a proxy serves
    # BURST_LIMIT requests back-to-back, then rests `Scraper.burst_cooldown` seconds
    # before it may be acquired again. The cooldown is a per-scraper property —
    # Cloudflare-protected Dou rests longer than the CF-free Djinni.
    BURST_LIMIT     = 15
    MIN_LIVE        = 10    # refill only when the pool is nearly empty
    BATCH_SIZE      = 1500  # max proven proxies pulled per load (validation budget)
    DISCOVERY_BATCH = 300   # untested proxies pulled only to bootstrap a pool with no proven ones
    REFILL_INTERVAL = 5     # min seconds between DB refills when the pool is small

    def initialize(db, source)
      @db            = db
      @source        = source
      @burst_cooldown = source.scraper.constantize.burst_cooldown
      @validation_url = source.scraper.constantize.validation_url(source)
      @entries       = []
      @by_id         = {}
      @known_ids     = Set.new
      @pending_fail  = []
      @pending_succ  = Hash.new(0)
      @dropped       = 0
      @refilling     = false
      @drained       = false
      @last_refill_at = 0.0
      seed_initial
      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if @entries.empty?
    end

    def size
      @entries.size
    end

    def dropped
      @dropped
    end

    # Returns a usable Proxy (cooled down and not in use) or nil when the pool is
    # momentarily busy. nil + `exhausted?` means there are genuinely no proxies left.
    def acquire
      maybe_refill

      now   = monotonic
      entry = @entries.find { |e| !e.in_use && e.available_at <= now }
      return nil unless entry

      entry.in_use = true
      entry.proxy
    end

    # status:
    #   :success — request returned data; buffer success counter + cool down
    #   :dead    — DeadProxyError; drop from rotation + buffer fail counter
    #   :keep    — worked but no stat change (empty page) or transient error; cool down
    def release(proxy, status: :keep)
      return unless proxy
      entry = @by_id[proxy.id]

      case status
      when :dead
        drop(entry, proxy)
        @pending_fail << proxy
        @dropped += 1
      when :success
        @pending_succ[proxy] += 1
        cool_down(entry)
      else
        cool_down(entry)
      end
    end

    def exhausted?
      @drained && @entries.empty?
    end

    # Persist everything buffered in memory. Called once when the run finishes.
    def flush!
      with_db { flush_pending }
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Count one request against the proxy's burst; keep it immediately reusable until
    # it has served BURST_LIMIT requests, then rest BURST_COOLDOWN seconds.
    def cool_down(entry)
      return unless entry
      entry.in_use = false
      entry.burst += 1
      if entry.burst >= BURST_LIMIT
        entry.burst = 0
        entry.available_at = monotonic + @burst_cooldown
      else
        entry.available_at = monotonic
      end
    end

    def drop(entry, proxy)
      @entries.delete(entry) if entry
      @by_id.delete(proxy.id)
      @known_ids.delete(proxy.id)
    end

    def maybe_refill
      return if @refilling
      return unless @entries.empty? ||
                    (@entries.size < MIN_LIVE && monotonic - @last_refill_at >= REFILL_INTERVAL)
      refill
    end

    # Initial pool: load proven candidates, validate them live (so only currently-
    # working proxies enter the pool), seed. Validation needs a reactor, so wrap in
    # Sync (this runs before the operation's own Async blocks).
    def seed_initial
      candidates = with_db { candidate_proxies }
      mark_known(candidates)
      live = VALIDATE_PROVEN_ON_START ? Sync { probe_alive(candidates) } : candidates
      add_entries(live, monotonic)
      @last_refill_at = monotonic
      @drained = true if candidates.empty?
    end

    # Probe candidates concurrently through their proxy; keep only those that tunnel.
    # Validate with the fast pure-Ruby AsyncHttp (no curl subprocess). Accept 2xx/3xx,
    # OR a 403 Cloudflare challenge — the proxy reached the site and is alive; the CF
    # source scrapes it via ImpersonateHttp (Chrome TLS), which clears the challenge.
    def probe_alive(candidates)
      live    = Concurrent::Array.new
      barrier = Async::Barrier.new
      semaphore = Async::Semaphore.new(VALIDATION_CONCURRENCY, parent: barrier)
      candidates.each do |proxy|
        semaphore.async do
          client   = ApplyMate::Client::AsyncHttp.new(proxy: proxy.url, request_timeout: HTTP_REQUEST_TIMEOUT, connect_timeout: HTTP_CONNECT_TIMEOUT)
          live << proxy if client.get(@validation_url)&.alive_or_cf_challenge?
        rescue StandardError
          nil
        end
      end
      barrier.wait
      live.to_a
    end

    # Refill mid-run also validates (like seed) — so when the pool depletes during a
    # long phase it tops up with *live* proxies, not dead ones that would churn. We're
    # already inside the reactor here, so probe_alive runs directly (no Sync wrapper).
    def refill
      return if @refilling
      @refilling = true

      candidates = with_db { flush_pending; candidate_proxies }
      mark_known(candidates)
      live = if candidates.empty? || !VALIDATE_PROVEN_ON_START
        candidates
      else
        probe_alive(candidates)
      end
      add_entries(live, monotonic)
      @last_refill_at = monotonic
      @drained = true if candidates.empty? && @entries.empty?
    ensure
      @refilling = false
    end

    # Proxies that work for THIS source, best-first — read from proxy_source_stats
    # (the validator maintains them per source). Bootstrap fallback: a pool with no
    # per-source stats yet (fresh DB / tests) pulls untested proxies.
    def candidate_proxies
      known = @known_ids.to_a

      working = Proxy
                .joins(:proxy_source_stats)
                .where(proxy_source_stats: { source_id: @source.id })
                .where('proxy_source_stats.success_count > 0')
                .where('proxy_source_stats.failed_at IS NULL OR proxy_source_stats.failed_at < ?', 1.minute.ago)
                .where.not(id: known)
                .order(Arel.sql('proxy_source_stats.reliability DESC, proxy_source_stats.success_count DESC'))
                .limit(BATCH_SIZE)
                .to_a
      return working if working.any?

      # Bootstrap: no proven proxies for this source yet — try untested ones.
      # NOT EXISTS (anti-join), not NOT IN (subquery): the latter scans ~1M proxies and
      # pegs Postgres for minutes (and keeps running after the job is killed).
      Proxy.where('NOT EXISTS (SELECT 1 FROM proxy_source_stats WHERE proxy_source_stats.proxy_id = proxies.id AND proxy_source_stats.source_id = ?)', @source.id)
           .where.not(id: known)
           .limit(DISCOVERY_BATCH).to_a
    end

    # Every candidate we have already looked at — live or not. `candidate_proxies`
    # excludes these, so a proxy that fails `probe_alive` is not re-selected on the
    # next refill. Without this only *live* proxies were remembered, so a pool whose
    # candidates were all dead re-queried and re-probed the same list forever:
    # `candidates` never went empty, `@drained` never flipped, `exhausted?` never
    # returned true and every worker fiber span on `sleep(0.2)` until the job was killed.
    def mark_known(proxies)
      @known_ids.merge(proxies.map(&:id))
    end

    def add_entries(proxies, now)
      proxies.each do |proxy|
        next if @by_id.key?(proxy.id)
        entry = Entry.new(proxy, now, false, 0)
        @entries << entry
        @by_id[proxy.id] = entry
        @known_ids << proxy.id
      end
    end

    # Persist buffered success/fail counters for THIS source into proxy_source_stats
    # in one bulk upsert. Current per-source counts are loaded from the DB (the proxy
    # object doesn't carry them) and bumped. Pruning of bad proxies is left to a job.
    def flush_pending
      return if @pending_succ.empty? && @pending_fail.empty?

      # Yield-free swap. `release` keeps appending while the upsert below suspends
      # this fiber; detaching the buffers first means those counters stay queued for
      # the next flush instead of being wiped by a `clear` that never saw them.
      succ, @pending_succ  = @pending_succ, Hash.new(0)
      fails, @pending_fail = @pending_fail, []

      now  = Time.current
      rows = {}

      succ.each do |proxy, count|
        row = (rows[proxy.id] ||= delta_row(proxy))
        row[:success_count] += count
      end

      fails.each do |proxy|
        row = (rows[proxy.id] ||= delta_row(proxy))
        row[:fail_count] += 1
        row[:failed_at]   = now
      end

      # Only used for the INSERT branch; the UPDATE branch recomputes from the
      # summed totals (see ProxySourceStat.apply_deltas!).
      rows.each_value { |row| row[:reliability] = ProxySourceStat.reliability_for(row[:success_count], row[:fail_count]) }

      begin
        ProxySourceStat.apply_deltas!(rows.values)
      rescue StandardError
        # Re-queue the detached counters so a failed upsert doesn't silently discard
        # them (same restore-on-error contract as VacancyBuffer#flush).
        succ.each { |proxy, count| @pending_succ[proxy] += count }
        @pending_fail.concat(fails)
        raise
      end
    end

    # A zeroed increment row for this (proxy, source) pair.
    def delta_row(proxy)
      {
        proxy_id:      proxy.id,
        source_id:     @source.id,
        success_count: 0,
        fail_count:    0,
        failed_at:     nil,
        reliability:   1.0
      }
    end

    def with_db(&block)
      @db.call(&block)
    end
  end

  # In-memory buffer for scraped vacancies (Phase 1). Workers append listings here
  # instead of writing per page; the DB is touched only when the buffer reaches
  # VACANCY_BUFFER_LIMIT (bulk upsert + ES import) or on the final flush at the end
  # of a source. One buffer per source — sources run concurrently and
  # `clean_old_vacancies` is per source.
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

  def perform!(sources: Source.all, **)
    skip_authorize

    @session_id = (Time.current.to_f * 1000).to_i
    @db         = DbGateway.new

    # One proxy pool per source, each seeded with proxies validated against THAT
    # source's host — the alive sets barely overlap (dou blocks proxies djinni
    # allows and vice-versa), so a shared pool starves whichever source it wasn't
    # validated for. A source with zero working proxies (e.g. a transient
    # Cloudflare block during seed) is skipped and logged, not fatal — the other
    # sources still sync. Only an empty run overall raises NoProxiesError.
    @pools  = {}
    sources = sources.select do |source|
      @pools[source.id] = ProxyPool.new(@db, source)
      true
    rescue NoProxiesError
      log(event: 'vacancy_sync_source_skipped', session_id: @session_id,
          source: source.name, reason: 'no_proxies', level: :warn)
      false
    end
    raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if sources.empty?

    log(event: 'vacancy_sync_started', session_id: @session_id,
        available_proxies: @pools.values.sum(&:size), total_proxies: Proxy.count, started_at_ms: @session_id)

    log(event: 'vacancy_sync_completed', session_id: @session_id) do
      # Pipeline per source: each source runs its own listing → description in one
      # fiber, all sources concurrent. So Dou's descriptions start the moment Dou's
      # listing finishes instead of waiting for every source's listing (Djinni's
      # listing is the slow one) — wall time = max over sources of (listing + desc).
      Async do |top_task|
        sources.map do |source|
          top_task.async do
            sync_source(source)
            # Sources whose listing already carries the description (Djinni) have no
            # second pass — there is no detail page left to visit.
            fetch_description_for_source(source) if source.scraper.constantize.fetches_description?
          end
        end.each(&:wait)
      end
    end
  ensure
    @pools&.each_value(&:flush!)
  end

  private

  def sync_source(source)
    pool = @pools[source.id]
    log(event: 'vacancy_sync_source_completed', session_id: @session_id, source: source.name, phase: 'listing') do
      external_ids  = Concurrent::Array.new
      pages_queue   = (1..MAX_PAGES).to_a
      last_page     = { counts: Hash.new(0), boundary: nil }
      scraped_pages = Set.new
      stop          = [ false ]
      buffer        = VacancyBuffer.new(@db, source)
      barrier       = Async::Barrier.new

      WORKERS_PER_SOURCE.times do
        barrier.async { scrape_pages(source, pages_queue, external_ids, last_page, scraped_pages, stop, buffer, pool) }
      end

      barrier.wait

      # Drain the buffer BEFORE deciding the source failed. It holds up to
      # VACANCY_BUFFER_LIMIT already-scraped vacancies, and `perform!`'s ensure only
      # flushes proxy counters — raising first threw that work away.
      buffer.flush

      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]

      # external_ids could have duplicates
      log(event: 'vacancy_sync_listing_summary', session_id: @session_id, source: source.name,
          pages: scraped_pages.size, vacancies: external_ids.size, proxies_deleted: pool.dropped)

      clean_old_vacancies(source, external_ids)
    end
  end

  def fetch_description_for_source(source)
    pool = @pools[source.id]
    log(event: 'vacancy_sync_source_completed', session_id: @session_id, source: source.name, phase: 'description') do
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
          barrier.async { fetch_description_worker(source, vacancies_queue, done, updates, retry_counts, stop, skipped, pool) }
        end

        barrier.wait

        # One bulk write per cursor-batch instead of an UPDATE per vacancy.
        if updates.any?
          rows = updates.to_a
          with_db do
            bulk_update_descriptions(rows)
            Vacancy.where(id: rows.map { |r| r[:id] }).import
          end
        end
      end

      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]

      log(event: 'vacancy_sync_description_summary', session_id: @session_id, source: source.name,
          descriptions: done[0], total: total, skipped: skipped[0],
          max_attempt: retry_counts.values.max || 0, proxies_deleted: pool.dropped)
    end
  end

  def fetch_description_worker(source, vacancies_queue, done, updates, retry_counts, stop, skipped, pool)
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
            log(event: 'vacancy_sync_no_proxies', source: source.name, phase: 'description', vacancy_external_id: vacancy.external_id, level: :error)
            vacancies_queue.unshift(vacancy)
            break
          end
          vacancies_queue.unshift(vacancy)
          sleep(0.2)
          next
        end

        client  = scraper_class.http_client_class.new(proxy: proxy.url, request_timeout: HTTP_REQUEST_TIMEOUT, connect_timeout: HTTP_CONNECT_TIMEOUT)
        scraper = scraper_class.new(source, client)
        html    = scraper.fetch_description(vacancy.url)

        if html.present?
          # Store the markup as the source wrote it and derive the plain-text column
          # from that same string, so the two can never describe different content.
          updates << { id: vacancy.id, description_html: html, description: scraper_class.to_plain_text(html) }
          done[0] += 1
          pool.release(proxy, status: :success)
          proxy = nil
        else
          count = retry_counts[vacancy.id] += 1
          if count >= MAX_VACANCY_RETRIES
            skipped[0] += 1
          else
            vacancies_queue.unshift(vacancy)
          end
        end
      rescue ApplyMate::Scraper::Base::DeadProxyError
        pool.release(proxy, status: :dead)
        proxy = nil
        vacancies_queue.unshift(vacancy)
        retry
      rescue StandardError => e
        log(event: 'vacancy_sync_description_error', source: source.name, host: proxy&.host, vacancy_external_id: vacancy&.external_id, error: e.message, error_class: e.class.name, level: :error)
        pool.release(proxy, status: :keep)
        proxy = nil
        vacancies_queue.unshift(vacancy)
        retry
      ensure
        pool.release(proxy, status: :keep)
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

  def scrape_pages(source, pages_queue, external_ids, last_page, scraped_pages, stop, buffer, pool)
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

        client  = source.scraper.constantize.http_client_class.new(proxy: proxy.url, request_timeout: HTTP_REQUEST_TIMEOUT, connect_timeout: HTTP_CONNECT_TIMEOUT)
        scraper = source.scraper.constantize.new(source, client)
        listing = scraper.fetch_listing(page: page)

        if listing&.any?
          scraped_pages << page
          last_page[:counts].delete_if { |p, _| p <= scraped_pages.max }
          buffer.add(listing)
          external_ids.concat(listing.map(&:external_id))
          buffer.maybe_flush
          pool.release(proxy, status: :success)
          proxy = nil
        else
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
            pages_queue.unshift(page)
          end
        end
      rescue ApplyMate::Scraper::Base::DeadProxyError
        pool.release(proxy, status: :dead)
        proxy = nil
        pages_queue.unshift(page)
        retry
      rescue StandardError
        pool.release(proxy, status: :keep)
        proxy = nil
        pages_queue.unshift(page)
        retry
      ensure
        pool.release(proxy, status: :keep)
        proxy = nil
      end
    end
  end

  def with_db(&block)
    @db.call(&block)
  end

  def clean_old_vacancies(source, active_ids)
    return if active_ids.empty?
    deleted = source.vacancies.where.not(external_id: active_ids.uniq).destroy_all
    log(event: 'vacancy_sync_stale_vacancies_deleted', source: source.name, count: deleted.size)
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
