# frozen_string_literal: true

class Apply::Operation::FetchForm < ApplyMate::Operation::Base
  def perform!(apply:, **)
    skip_authorize
    self.model = apply

    return if apply.error.present?

    apply.update!(status: :fetching_form)
    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)

    source = apply.vacancy.source
    client = source.client.constantize.new
    scraper = ApplyMate::Scraper::Djinni.new(source, client)

    session_id = apply.source_profile&.session_id

    form_data = scraper.fetch_form_data(apply.vacancy.url, session_id:)

    if form_data.present?
      apply.update!(form_data: form_data.to_h, status: :pending)
    else
      apply.update!(status: :failed_fetching_form, error: 'Form not found on the page. Check if you are logged in or if the vacancy is still open.')
      raise 'Form not found'
    end

    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)
  rescue StandardError => e
    apply.update!(status: :failed_fetching_form, error: e.message)
    Apply::TurboHandler::StatusUpdate.broadcast(apply.vacancy)
    raise
  end
end
