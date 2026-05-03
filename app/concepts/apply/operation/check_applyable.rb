# frozen_string_literal: true

class Apply::Operation::CheckApplyable < ApplyMate::Operation::Base
  def perform!(apply:, **)
    skip_authorize
    self.model = apply

    apply.update!(status: :checking_applyble)
    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)

    source = apply.vacancy.source
    client = source.client.constantize.new
    scraper = ApplyMate::Scraper::Djinni.new(source, client)

    # TODO
    session_id = apply.source_profile.session_id

    applyble = scraper.fetch_applyble(apply.vacancy.url, session_id:)

    unless applyble
      apply.update!(applyble: false, status: :failed_checking_applyble, error: 'Vacancy is not applyable')
      raise 'Vacancy is not applyable'
    end

    apply.update!(applyble: true, status: :pending)
    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)
  rescue StandardError => e
    apply.update!(status: :failed_checking_applyble, error: e.message)
    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)
    raise
  end
end
