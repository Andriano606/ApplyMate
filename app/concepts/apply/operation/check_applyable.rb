# frozen_string_literal: true

class Apply::Operation::CheckApplyable < Apply::Operation::Base
  def start_status
    :checking_applyble
  end

  def error_status
    :failed_checking_applyble
  end

  private

  def run!(apply:, **)
    scraper    = apply.vacancy.source.build_scraper
    session_id = apply.source_profile.session_id
    applyble   = scraper.fetch_applyble(apply.vacancy.url, session_id:)

    unless applyble
      apply.update!(applyble: false)
      raise 'Vacancy is not applyable'
    end

    apply.update!(applyble: true)
  end
end
