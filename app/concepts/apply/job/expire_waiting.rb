# frozen_string_literal: true

# Recurring (config/recurring.yml) on the general queue.
class Apply::Job::ExpireWaiting < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: 'apply_expire_waiting', duration: 30.minutes

  def perform
    Apply::Operation::Engine::ExpireWaiting.call
  end
end
