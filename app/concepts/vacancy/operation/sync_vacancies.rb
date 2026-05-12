# frozen_string_literal: true

require 'async'

class Vacancy::Operation::SyncVacancies < ApplyMate::Operation::Base
  include ApplyMate::Logging

  NoProxiesError = Class.new(StandardError)

  WORKERS_PER_SOURCE      = 200
  MAX_PAGES               = 2000
  LAST_PAGE_CONFIRMATIONS = 50

  def perform!(**)
    skip_authorize
    proxy_count = Proxy.ready_for_use.count
    raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if proxy_count.zero?

    log("Available proxies: #{proxy_count}", color: :green)

    log_time('SyncVacancies') do
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
    log_time(source.name) do
      external_ids     = Concurrent::Array.new
      pages_queue      = (1..MAX_PAGES).to_a
      in_use_proxy_ids = Set.new
      last_page        = { counts: Hash.new(0), boundary: nil }
      stop             = [ false ]
      barrier          = Async::Barrier.new

      WORKERS_PER_SOURCE.times do
        barrier.async { scrape_pages(source, pages_queue, in_use_proxy_ids, external_ids, last_page, stop) }
      end

      barrier.wait
      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]

      clean_old_vacancies(source, external_ids)
    end
  end

  def fetch_description_for_source(source)
    log_time("#{source.name} description") do
      vacancies_queue  = source.vacancies.to_a
      total            = vacancies_queue.size
      done             = [ 0 ]
      in_use_proxy_ids = Set.new
      updated_ids      = Concurrent::Array.new
      stop             = [ false ]
      barrier          = Async::Barrier.new

      WORKERS_PER_SOURCE.times do
        barrier.async { fetch_description_worker(source, vacancies_queue, in_use_proxy_ids, total, done, updated_ids, stop) }
      end

      barrier.wait
      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]

      Vacancy.where(id: updated_ids).import if updated_ids.any?
    end
  end

  def fetch_description_worker(source, vacancies_queue, in_use_proxy_ids, total, done, updated_ids, stop)
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
            log("#{ctx(source, vacancy.external_id)} #{I18n.t('vacancy.sync.no_proxies')}", color: :red)
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

        if description.present?
          with_db do
            proxy.increment_succeeded!
            vacancy.update_column(:description, description)
          end
          updated_ids << vacancy.id
          done[0] += 1
          log("#{ctx(source, vacancy.external_id, proxy)} #{done[0] * 100 / total}% (#{done[0]}/#{total})", color: :green)
        else
          log("#{ctx(source, vacancy.external_id, proxy)} no description, skipping", color: :yellow)
        end
      rescue ApplyMate::Client::Base::DeadProxyError
        with_db { proxy&.increment_fail! }
        release_proxy(proxy, in_use_proxy_ids)
        proxy = nil
        vacancies_queue.unshift(vacancy)
        retry
      rescue StandardError => e
        log("#{ctx(source, vacancy.external_id, proxy)} error: #{e.message}", color: :red)
        release_proxy(proxy, in_use_proxy_ids)
        proxy = nil
        vacancies_queue.unshift(vacancy)
        retry
      ensure
        release_proxy(proxy, in_use_proxy_ids)
      end
    end
  end

  def scrape_pages(source, pages_queue, in_use_proxy_ids, external_ids, last_page, stop)
    loop do
      break if stop[0]

      begin
        client = nil
        proxy  = nil
        page   = pages_queue.shift
        break unless page
        break if last_page[:boundary] && page >= last_page[:boundary]

        proxy = acquire_proxy(in_use_proxy_ids)
        unless proxy
          if with_db { Proxy.count.zero? }
            stop[0] = true
            log("#{ctx(source, "p#{page}")} #{I18n.t('vacancy.sync.no_proxies')}", color: :red)
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
          with_db do
            proxy.increment_succeeded!
            sync_vacancies_batch(listing, source)
          end
          log("#{ctx(source, "p#{page}", proxy)} #{listing.size} items", color: :green)
          external_ids.concat(listing.map(&:external_id))
        else
          last_page[:counts][page] += 1
          count = last_page[:counts][page]

          if count >= LAST_PAGE_CONFIRMATIONS
            last_page[:boundary] = [ last_page[:boundary], page ].compact.min
            log("#{ctx(source, "p#{page}", proxy)} confirmed last page (#{count} empty hits)", color: :yellow)
            next
          elsif count == 1
            (LAST_PAGE_CONFIRMATIONS - 1).times { pages_queue.unshift(page) }
          end
        end
      rescue ApplyMate::Client::Base::DeadProxyError
        with_db { proxy&.increment_fail! }
        release_proxy(proxy, in_use_proxy_ids)
        proxy = nil
        pages_queue.unshift(page)
        retry
      rescue StandardError => e
        log("#{ctx(source, "p#{page}", proxy)} error: #{e.message}", color: :red)
        release_proxy(proxy, in_use_proxy_ids)
        proxy = nil
        pages_queue.unshift(page)
        retry
      ensure
        release_proxy(proxy, in_use_proxy_ids)
      end
    end
  end

  def acquire_proxy(in_use_proxy_ids)
    ActiveRecord::Base.connection_pool.with_connection do
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

  def with_db(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end

  def ctx(source, label, proxy = nil)
    fiber_id = Fiber.current.object_id.to_s.last(4)
    "[#{source.name}|#{label}|#{proxy&.host || '—'}|f#{fiber_id}]"
  end

  def clean_old_vacancies(source, active_ids)
    return if active_ids.empty?
    deleted = source.vacancies.where.not(external_id: active_ids.uniq).destroy_all
    log("Deleted #{deleted.size} stale vacancies for #{source.name}", color: :gray)
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
