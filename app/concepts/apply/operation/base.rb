# frozen_string_literal: true

class Apply::Operation::Base < ApplyMate::Operation::Base
  # Raised when automation is impossible in principle (captcha challenge, account
  # wall) — carries its own status so the rescue below records the specific
  # blocker instead of the step's generic error_status.
  class BlockedError < StandardError
    attr_reader :status

    def initialize(status, message)
      @status = status
      super(message)
    end
  end

  def start_status
    raise NotImplementedError, "#{self.class} must define start_status"
  end

  def error_status
    raise NotImplementedError, "#{self.class} must define error_status"
  end

  def success_status
    nil
  end

  def perform!(apply:, handler: nil, **options)
    skip_authorize
    self.model = apply

    return if apply.error.present?

    apply.update!(status: start_status)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)

    run!(apply:, handler:, **options)

    if success_status
      apply.update!(status: success_status)
      Apply::TurboHandler::StatusUpdate.broadcast(apply)
    end
  rescue BlockedError => e
    apply.update!(status: e.status, error: e.message)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)
    raise e
  rescue StandardError => e
    apply.update!(status: error_status, error: e.message)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)
    raise e
  ensure
    cleanup
  end

  private

  def run!(apply:, handler:, **)
    raise NotImplementedError, "#{self.class} must define run!"
  end

  def cleanup; end
end
