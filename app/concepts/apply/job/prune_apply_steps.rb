# frozen_string_literal: true

# Recurring (config/recurring.yml) on the general queue.
class Apply::Job::PruneApplySteps < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: 'apply_prune_apply_steps', duration: 1.hour

  def perform
    Apply::Operation::Engine::PruneApplySteps.call
  end
end
