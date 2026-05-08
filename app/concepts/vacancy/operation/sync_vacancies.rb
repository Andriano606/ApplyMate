# frozen_string_literal: true

require 'async'

class Vacancy::Operation::SyncVacancies < ApplyMate::Operation::Base
  def perform!(**)
    started_at = Time.current

    Async do
      tasks = Source.all.map do |source|
        Async do
          client = ApplyMate::Client::AsyncHttp.new
          begin
            on_batch = ->(data) do
              sync_vacancies_batch(data, source)
            end

            format_result = ->(data) { data.map(&:external_id) }

            all_external_ids = source.scraper.constantize.new(source, client).fetch_listing(on_batch:, format_result:)

            source.vacancies.where.not(external_id: all_external_ids.uniq).destroy_all
          ensure
            client.close
          end
        end
      end
      tasks.each(&:wait)
    end

    Rails.logger.info "[SyncVacancies] Total time: #{(Time.current - started_at).round(1)}s"
  end

  private

  def sync_vacancies_batch(data, source)
    return if data.blank?
    data = data.compact
    data = data.uniq(&:external_id)

    Vacancy.upsert_all(
      data.map(&:to_h),
      unique_by: [ :source_id, :external_id ],
      update_only: [ :title, :description, :url, :company_name, :company_icon_url ],
      record_timestamps: true
    )

    Vacancy.where(source_id: source.id, external_id: data.map(&:external_id)).import
  end
end
