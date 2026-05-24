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
      scraped_pages    = Set.new
      active_fibers    = [ 0 ]
      stop             = [ false ]
      barrier          = Async::Barrier.new

      WORKERS_PER_SOURCE.times do
        barrier.async { scrape_pages(source, pages_queue, in_use_proxy_ids, external_ids, last_page, scraped_pages, active_fibers, stop) }
      end

      barrier.wait
      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]

      clean_old_vacancies(source, external_ids)
    end
  end

  def fetch_description_for_source(source)
    log_time("#{source.name} description") do
      vacancies_queue  = source.vacancies.order(:id).to_a
      total            = vacancies_queue.size
      done             = [ 0 ]
      in_use_proxy_ids = Set.new
      updated_ids      = Concurrent::Array.new
      retry_counts     = Hash.new(0)
      stop             = [ false ]
      barrier          = Async::Barrier.new

      WORKERS_PER_SOURCE.times do
        barrier.async { fetch_description_worker(source, vacancies_queue, in_use_proxy_ids, total, done, updated_ids, retry_counts, stop) }
      end

      barrier.wait
      raise NoProxiesError, I18n.t('vacancy.sync.no_proxies') if stop[0]

      Vacancy.where(id: updated_ids).import if updated_ids.any?
    end
  end

  def fetch_description_worker(source, vacancies_queue, in_use_proxy_ids, total, done, updated_ids, retry_counts, stop)
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

        if description == 'SKIPP'
          log("#{ctx(source, vacancy.external_id, proxy)} no description, skipp...", color: :yellow)
          break
        elsif description == 'SKIP_VACANCY'
          log("#{ctx(source, vacancy.external_id, proxy)} vacancy gone, skipping...", color: :yellow)
          next
        elsif description.present?
          with_db do
            proxy.increment_succeeded!
            vacancy.update_column(:description, description)
          end
          updated_ids << vacancy.id
          done[0] += 1
          log("#{ctx(source, vacancy.external_id, proxy)} #{done[0] * 100 / total}% (#{done[0]}/#{total})", color: :green)
        else
          count = retry_counts[vacancy.id] += 1
          if count >= MAX_VACANCY_RETRIES
            log("#{ctx(source, vacancy.external_id, proxy)} no description after #{MAX_VACANCY_RETRIES} retries, giving up", color: :red)
          else
            log("#{ctx(source, vacancy.external_id, proxy)} no description url(#{vacancy.url}), retry #{count}/#{MAX_VACANCY_RETRIES}...", color: :yellow)
            vacancies_queue.unshift(vacancy)
          end
        end
      rescue ApplyMate::Client::Base::DeadProxyError
        log("#{ctx(source, vacancy.external_id, proxy)} error: Dead Proxy", color: :red)
        with_db { proxy&.increment_fail! }
        vacancies_queue.unshift(vacancy)
        retry
      rescue StandardError => e
        log("#{ctx(source, vacancy.external_id, proxy)} error: #{e.message}", color: :red)
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

    if with_db { Proxy.count.zero? }
      stop[0] = true
      return true
    end

    return false unless last_page[:boundary]
    last_page = (last_page[:boundary] - 1)
    true if scraped_pages.max == last_page && scraped_pages.size == last_page
  end

  def next_fiber_condition(page, scraped_pages, last_page)
    true if (last_page[:boundary] && page >= last_page[:boundary]) ||
                   (scraped_pages.any? && scraped_pages.include?(page))
  end

  def clean_boundary_pages(scraped_pages, last_page)
    last_page[:counts].delete_if { |p, _| scraped_pages.include?(p) || (!scraped_pages.max.nil? && scraped_pages.max >= p) }
  end

  def clean_pages_queue(pages_queue, last_page, scraped_pages)
    pages_queue.sort!
    return unless last_page[:boundary]
    pages_queue.delete_if { |a| a >= last_page[:boundary] || scraped_pages.include?(a) }
  end

  def scrape_pages(source, pages_queue, in_use_proxy_ids, external_ids, last_page, scraped_pages, active_fibers, stop)
    active_fibers[0] += 1
    loop do
      begin
        client = nil
        proxy  = nil

        clean_boundary_pages(scraped_pages, last_page)
        clean_pages_queue(pages_queue, last_page, scraped_pages)

        page   = pages_queue.shift

        break if break_fiber_condition(scraped_pages, last_page, stop, page)
        next if next_fiber_condition(page, scraped_pages, last_page)

        # DEBUG LOG
        fiber_id = Fiber.current.object_id.to_s.last(4)
        upcoming = pages_queue.first(WORKERS_PER_SOURCE)
        candidate_page, candidate_count = last_page[:counts].max_by { |_, v| v }
        if source.name == 'Djinni'
          log(
    "[#{source.name} p(#{page}) f(#{fiber_id})] fibers:#{active_fibers[0]} " \
            "scraped:#{scraped_pages.size}(#{scraped_pages.min || '-'}..#{scraped_pages.max || '-'}) " \
            "boundary:#{last_page[:boundary] || '?'} " \
            "candidate:#{candidate_page || '?'}(#{candidate_count || 0}/#{LAST_PAGE_CONFIRMATIONS}) " \
            "queue_head[#{WORKERS_PER_SOURCE}]: first=#{upcoming.first} min=#{upcoming.min} max=#{upcoming.max}"
          )
          log("pages_queue (#{pages_queue.size}): #{pages_queue if pages_queue.size < 5}")
        end

        proxy = acquire_proxy(in_use_proxy_ids)
        unless proxy
          log("#{ctx(source, "p#{page}", proxy)} error: NO PROXY", color: :red)
          pages_queue.unshift(page)
          sleep(5)
          next
        end

        client  = ApplyMate::Client::AsyncHttp.new(proxy: proxy.url)
        scraper = source.scraper.constantize.new(source, client)
        listing = scraper.fetch_listing(page: page)

        if listing&.any?
          scraped_pages << page
          with_db do
            proxy.increment_succeeded!
            sync_vacancies_batch(listing, source)
          end
          # log("#{ctx(source, "p#{page}", proxy)} #{listing.size} items", color: :green)
          external_ids.concat(listing.map(&:external_id))
        else
          if scraped_pages.empty? || (scraped_pages.any? && page > scraped_pages.max)
            last_page[:counts][page] += 1
            count = last_page[:counts][page]

            if count >= LAST_PAGE_CONFIRMATIONS
              last_page[:boundary] = [ last_page[:boundary], page ].compact.min
            elsif count == 1
              LAST_PAGE_CONFIRMATIONS.times { pages_queue.unshift(page) }
            end
          else
            pages_queue.unshift(page)
          end
        end
      rescue ApplyMate::Client::Base::DeadProxyError => e
        log("#{ctx(source, "p#{page}", proxy)} error: #{e.message}", color: :red)
        with_db { proxy&.increment_fail! }
        pages_queue.unshift(page)
        retry
      rescue StandardError => e
        log("#{ctx(source, "p#{page}", proxy)} error: #{e.message}", color: :red)
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
    # log("Deleted #{deleted.size} stale vacancies for #{source.name}", color: :gray)
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
