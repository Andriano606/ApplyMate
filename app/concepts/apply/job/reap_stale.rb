# frozen_string_literal: true

# Recurring (config/recurring.yml) on the general queue: never launches a browser. The job must not raise
# (design §1.2): a failing sweep is reported and the next minute tries again.
class Apply::Job::ReapStale < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: 'apply_reap_stale', duration: 10.minutes

  def perform
    Apply::Operation::Engine::ReapStale.call
  rescue StandardError => e
    Rails.logger.error("[Apply::Job::ReapStale] #{e.class}: #{e.message}")
    Rails.error.report(e, handled: true)
  end
end
