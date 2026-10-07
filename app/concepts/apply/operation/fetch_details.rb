# frozen_string_literal: true

class Apply::Operation::FetchDetails < Apply::Operation::Base
  stage :fetch_details

  private

  def run!(apply:, **)
    scraper = apply.vacancy.source.build_scraper
    details = scraper.fetch_details(apply.vacancy.url)
    apply.vacancy.update!(details: details) if details.present?
  end
end
