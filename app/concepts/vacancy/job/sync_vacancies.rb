# frozen_string_literal: true

class Vacancy::Job::SyncVacancies < ApplicationJob
  queue_as :default

  def perform
    Source.all.each do |source|
      vacancies_data = source.scraper.constantize.new(source, ApplyMate::Client::Http.new).fetch_listing
      sync_vacancies(vacancies_data, source)
    end
  end

  private

  def sync_vacancies(data, source)
    return if data.blank?
    data = data.compact
    data = data.uniq(&:external_id)
    current_external_ids = data.map { |d| d[:external_id] }

    Vacancy.transaction do
      Vacancy.upsert_all(
        data.map(&:to_h),
        unique_by: [ :source_id, :external_id ],
        update_only: [ :title, :description, :url, :company_name, :company_icon_url ],
        record_timestamps: true
      )

      source.vacancies.where.not(external_id: current_external_ids).destroy_all
    end

    Vacancy.import batch_size: 500
  end
end
