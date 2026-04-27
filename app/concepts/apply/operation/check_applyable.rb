# frozen_string_literal: true

class Apply::Operation::CheckApplyable < ApplyMate::Operation::Base
  def perform!(apply:, **)
    skip_authorize
    self.model = apply

    apply.update!(status: :checking_applyble)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)

    source = apply.vacancy.source
    client = source.client.constantize.new
    scraper = DjinniScraper.new(source, client)

    # TODO
    session_id = apply.source_profile.session_id

    applyble = scraper.fetch_applyble(apply.vacancy.url, session_id:)
    apply.update!(applyble:, status: :pending)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)
  rescue StandardError => e
    apply.update!(status: :failed_checking_applyble, error: e.message)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)
    raise
  end
end
