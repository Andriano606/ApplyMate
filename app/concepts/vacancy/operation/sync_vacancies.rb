# frozen_string_literal: true

require 'async'

class Vacancy::Operation::SyncVacancies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  NoProxiesError = Class.new(StandardError)

  WORKERS_PER_SOURCE      = 15
  MAX_PAGES               = 2000
  LAST_PAGE_CONFIRMATIONS = 50
  MAX_VACANCY_RETRIES     = 20

  def perform!(**)
    skip_authorize
    proxy_count = Proxy.ready_for_use.count
    raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if proxy_count.zero?

    @session_id = (Time.current.to_f * 1000).to_i

    log(event: 'vacancy_sync_started', session_id: @session_id, available_proxies: proxy_count, total_proxies: Proxy.count, started_at_ms: @session_id)

    log(event: 'vacancy_sync_completed', session_id: @session_id) do
      Async do |top_task|
        Source.all.map { |source| top_task.async { sync_source(source) } }.each(&:wait)
      end

      Async do |top_task|
        Source.all.map { |source| top_task.async { fetch_description_for_source(source) } }.each(&:wait)
      end
    end
  end

  private

  def sync_source(source)
    log(event: 'vacancy_sync_source_completed', session_id: @session_id, source: source.name, phase: 'listing') do
      external_ids     = Concurrent::Array.new
      pages_queue      = (1..MAX_PAGES).to_a
      in_use_proxy_ids = Set.new
      last_page        = { counts: Hash.new(0), boundary: nil }
      scraped_pages    = Set.new
      active_fibers    = [ 0 ]
      stop             = [ false ]
      deleted          = [ 0 ]
      barrier          = Async::Barrier.new

      WORKERS_PER_SOURCE.times do
        barrier.async { scrape_pages(source, pages_queue, in_use_proxy_ids, external_ids, last_page, scraped_pages, active_fibers, stop, deleted) }
      end

      barrier.wait
      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]

      # external_ids could have duplicates
      log(event: 'vacancy_sync_listing_summary', session_id: @session_id, source: source.name,
          pages: scraped_pages.size, vacancies: external_ids.size, proxies_deleted: deleted[0])

      clean_old_vacancies(source, external_ids)
    end
  end

  def fetch_description_for_source(source)
    log(event: 'vacancy_sync_source_completed', session_id: @session_id, source: source.name, phase: 'description') do
      vacancies_queue  = source.vacancies.select(:id, :external_id, :url).order(:id).to_a
      total            = vacancies_queue.size
      done             = [ 0 ]
      in_use_proxy_ids = Set.new
      updated_ids      = Concurrent::Array.new
      retry_counts     = Hash.new(0)
      skipped          = [ 0 ]
      deleted          = [ 0 ]
      stop             = [ false ]
      barrier          = Async::Barrier.new

      WORKERS_PER_SOURCE.times do
        barrier.async { fetch_description_worker(source, vacancies_queue, in_use_proxy_ids, total, done, updated_ids, retry_counts, stop, skipped, deleted) }
      end

      barrier.wait
      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]

      log(event: 'vacancy_sync_description_summary', session_id: @session_id, source: source.name,
          descriptions: done[0], total: total, skipped: skipped[0],
          max_attempt: retry_counts.values.max || 0, proxies_deleted: deleted[0])

      Vacancy.where(id: updated_ids).import if updated_ids.any?
    end
  end

  def fetch_description_worker(source, vacancies_queue, in_use_proxy_ids, total, done, updated_ids, retry_counts, stop, skipped, deleted)
    loop do
      break if stop[0]

      begin
        client  = nil
        proxy   = nil
        vacancy = vacancies_queue.shift
        break unless vacancy

        proxy = acquire_proxy(in_use_proxy_ids)
        unless proxy
          if with_db { Proxy.count.zero? }
            stop[0] = true
            log(event: 'vacancy_sync_no_proxies', source: source.name, phase: 'description', vacancy_external_id: vacancy.external_id, level: :error)
            vacancies_queue.unshift(vacancy)
            break
          end
          vacancies_queue.unshift(vacancy)
          sleep(5)
          next
        end

        client      = ApplyMate::Client::AsyncHttp.new(proxy: proxy.url)
        scraper     = source.scraper.constantize.new(source, client)
        description = scraper.fetch_description(vacancy.url)

        if description == 'SKIPP'
          break
        elsif description.present?
          with_db do
            proxy.increment_succeeded!
            vacancy.update_column(:description, description)
          end
          updated_ids << vacancy.id
          done[0] += 1
        else
          count = retry_counts[vacancy.id] += 1
          if count >= MAX_VACANCY_RETRIES
            skipped[0] += 1
          else
            vacancies_queue.unshift(vacancy)
          end
        end
      rescue ApplyMate::Client::Base::DeadProxyError
        deleted[0] += 1 if kill_proxy(proxy)
        release_proxy(proxy, in_use_proxy_ids)
        proxy = nil
        vacancies_queue.unshift(vacancy)
        retry
      rescue StandardError => e
        log(event: 'vacancy_sync_description_error', source: source.name, host: proxy&.host, vacancy_external_id: vacancy&.external_id, error: e.message, error_class: e.class.name, level: :error)
        release_proxy(proxy, in_use_proxy_ids)
        proxy = nil
        vacancies_queue.unshift(vacancy)
        retry
      ensure
        release_proxy(proxy, in_use_proxy_ids)
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

  def scrape_pages(source, pages_queue, in_use_proxy_ids, external_ids, last_page, scraped_pages, active_fibers, stop, deleted)
    active_fibers[0] += 1
    loop do
      begin
        client = nil
        proxy  = nil

        page = pages_queue.shift

        break if break_fiber_condition(scraped_pages, last_page, stop, page)
        next if next_fiber_condition(page, scraped_pages, last_page)

        proxy = acquire_proxy(in_use_proxy_ids)
        unless proxy
          if with_db { Proxy.count.zero? }
            stop[0] = true
            # log(event: 'vacancy_sync_no_proxies', source: source.name, phase: 'listing', page: page, level: :error)
            pages_queue.unshift(page)
            break
          end
          pages_queue.unshift(page)
          sleep(5)
          next
        end

        client  = ApplyMate::Client::AsyncHttp.new(proxy: proxy.url)
        scraper = source.scraper.constantize.new(source, client)
        listing = scraper.fetch_listing(page: page)

        if listing&.any?
          scraped_pages << page
          last_page[:counts].delete_if { |p, _| p <= scraped_pages.max }
          with_db do
            proxy.increment_succeeded!
            sync_vacancies_batch(listing, source)
          end
          external_ids.concat(listing.map(&:external_id))
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
      rescue ApplyMate::Client::Base::DeadProxyError
        deleted[0] += 1 if kill_proxy(proxy)
        release_proxy(proxy, in_use_proxy_ids)
        proxy = nil
        pages_queue.unshift(page)
        retry
      rescue StandardError => e
        # log(event: 'vacancy_sync_listing_error', source: source.name, host: proxy&.host, page: page, error: e.message, error_class: e.class.name, level: :error)
        release_proxy(proxy, in_use_proxy_ids)
        proxy = nil
        pages_queue.unshift(page)
        retry
      ensure
        release_proxy(proxy, in_use_proxy_ids)
        proxy = nil
      end
    end
  ensure
    active_fibers[0] -= 1
  end

  def acquire_proxy(in_use_proxy_ids)
    with_db do
      Proxy.transaction do
        proxy = Proxy.ready_for_use
                     .where.not(id: in_use_proxy_ids.to_a)
                     .lock('FOR UPDATE SKIP LOCKED')
                     .first
        if proxy
          in_use_proxy_ids << proxy.id
          proxy.mark_used!
        end
        proxy
      end
    end
  end

  def release_proxy(proxy, in_use_proxy_ids)
    return unless proxy
    in_use_proxy_ids.delete(proxy.id)
    return if proxy.destroyed?
    with_db { proxy.mark_used! }
  end

  def kill_proxy(proxy)
    return false unless proxy
    with_db { proxy.increment_fail! }
    proxy.destroyed?
  end

  def with_db(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end

  def clean_old_vacancies(source, active_ids)
    return if active_ids.empty?
    deleted = source.vacancies.where.not(external_id: active_ids.uniq).destroy_all
    log(event: 'vacancy_sync_stale_vacancies_deleted', source: source.name, count: deleted.size)
  end

  def sync_vacancies_batch(data, source)
    return if data.blank?
    data = data.compact.uniq(&:external_id)

    Vacancy.upsert_all(
      data.map(&:to_h),
      unique_by: [ :source_id, :external_id ],
      update_only: [ :title, :description, :url, :company_name, :company_icon_url ],
      record_timestamps: true
    )

    Vacancy.where(source_id: source.id, external_id: data.map(&:external_id)).import
  end
end
