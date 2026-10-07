# frozen_string_literal: true

class Apply::Operation::FetchApplyType < Apply::Operation::Base
  stage :fetch_apply_type

  private

  def run!(apply:, **)
    scraper    = apply.vacancy.source.build_scraper
    session_id = apply.source_profile.session_id

    info = scraper.fetch_apply_type(apply.vacancy.url, session_id:)

    unless info
      apply.update!(applyble: false)
      halt!(:no_application_path, detail: 'apply type not found')
    end

    apply.update!(apply_type: info[:type], applyble: true)
    apply.vacancy.update!(external_url: info[:external_url]) if info[:external_url].present?
  end
end
