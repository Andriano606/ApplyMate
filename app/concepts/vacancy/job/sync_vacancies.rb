# frozen_string_literal: true

class Vacancy::Job::SyncVacancies < ApplicationJob
  queue_as :default

  def perform
    Source.all.each do |source|
      client = source.client.constantize.new
      vacancies_data = DjinniScraper.new(source, client).perform
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
      # Оновлюємо/створюємо
      Vacancy.upsert_all(
        data.map(&:to_h),
        unique_by: [ :source_id, :external_id ],
        update_only: [ :title, :description, :url, :company_name, :company_icon_url ],
        record_timestamps: true
      )

      # Видаляємо старі
      source.vacancies.where.not(external_id: current_external_ids).destroy_all
    end

    # TODO: reindex
    Vacancy.__elasticsearch__.delete_index!
    Vacancy.__elasticsearch__.create_index!
    Vacancy.import
  end

  def parse_item(element)
    header_el = element.at_css('h2.job-item__position')
    raw_link  = element.at_css('.job-list-item__link, .job_item__header-link')&.[]('href')
    link      = full_url(raw_link)

    return nil if header_el.blank? || link.blank?

    {
      source_id:        @source.id,
      title:            header_el.text.strip,
      url:              link,
      description:      sanitize_html(element.at_css('.js-original-text')&.inner_html),
      company_name:     element.at_css('.small.text-gray-800')&.text&.strip,
      company_icon_url: element.at_css('img.userpic-image')&.[]('src'),
      external_id:      link.scan(/\d+/)&.first,
      created_at:       Time.current, # Потрібно для upsert_all
      updated_at:       Time.current
    }
  end
end
