# frozen_string_literal: true

class Apply::Operation::FetchApplyType < Apply::Operation::Base
  def start_status
    :fetching_apply_type
  end

  def error_status
    :failed_fetching_apply_type
  end

  private

  def run!(apply:, **)
    scraper    = apply.vacancy.source.build_scraper
    session_id = apply.source_profile.session_id

    info = scraper.fetch_apply_type(apply.vacancy.url, session_id:)

    unless info
      apply.update!(applyble: false)
      raise 'Could not determine apply type for this vacancy'
    end

    apply.update!(apply_type: info[:type], applyble: true)
    apply.vacancy.update!(external_url: info[:external_url]) if info[:external_url].present?
  end
end
