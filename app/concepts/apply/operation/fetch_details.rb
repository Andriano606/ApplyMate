# frozen_string_literal: true

class Apply::Operation::FetchDetails < ApplyMate::Operation::Base
  def perform!(apply:, **)
    skip_authorize
    self.model = apply

    return if apply.error.present?

    apply.update!(status: :fetching_details)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)

    source = apply.vacancy.source
    client = source.client.constantize.new
    scraper = DjinniScraper.new(source, client)

    details = scraper.fetch_details(apply.vacancy.url)
    apply.vacancy.update!(details: details) if details.present?

    apply.update!(status: :pending)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)
  rescue StandardError => e
    apply.update!(status: :failed_fetching_details, error: e.message)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)
    raise
  end
end
