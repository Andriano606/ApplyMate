# frozen_string_literal: true

class Apply::Operation::FetchDetails < Apply::Operation::Base
  def start_status
    :fetching_details
  end

  def error_status
    :failed_fetching_details
  end

  private

  def run!(apply:, **)
    scraper = apply.vacancy.source.build_scraper
    details = scraper.fetch_details(apply.vacancy.url)
    apply.vacancy.update!(details: details) if details.present?
  end
end
