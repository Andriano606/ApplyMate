# frozen_string_literal: true

class Apply::Operation::CheckApplyable < Apply::Operation::Base
  stage :check_applyable

  private

  def run!(apply:, **)
    scraper    = apply.vacancy.source.build_scraper
    session_id = apply.source_profile.session_id
    applyble   = scraper.fetch_applyble(apply.vacancy.url, session_id:)

    unless applyble
      apply.update!(applyble: false)
      halt!(:no_application_path, detail: 'no reply button')
    end

    apply.update!(applyble: true)
  end
end
