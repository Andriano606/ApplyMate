# frozen_string_literal: true

# Pushes an Apply's current state to the user's open pages (Apply::TurboHandler::StatusUpdate). Used by the
# Runner (stage changes) and Lifecycle (state changes). The state is already committed when this runs, so a
# failing render/broadcast is reported and swallowed: it must neither fail the run nor turn a recorded
# outcome into unexpected_error.
class Apply::Operation::Engine::Broadcast < ApplyMate::Operation::Base
  def perform!(apply:, **)
    skip_authorize
    self.model = apply.reload
    Apply::TurboHandler::StatusUpdate.broadcast(model)
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { apply: apply.hashid })
  end
end
