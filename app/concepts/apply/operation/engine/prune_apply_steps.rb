# frozen_string_literal: true

# Daily (Apply::Job::PruneApplySteps): apply_steps grow with every run, so rows finished more than RETENTION
# ago are deleted (rides index_apply_steps_on_finished_at; unfinished rows have NULL and are never matched).
# Applies themselves are never auto-deleted; deleting an apply removes its steps (dependent: :destroy).
# Bounded: BATCH_SIZE rows per DELETE, at most MAX_BATCHES per run. model: deleted row count.
class Apply::Operation::Engine::PruneApplySteps < ApplyMate::Operation::Base
  RETENTION = 180.days
  BATCH_SIZE = 1000
  MAX_BATCHES = 50

  def perform!(**)
    skip_authorize
    self.model = 0
    MAX_BATCHES.times do
      deleted = ApplyStep.where(id: expired_ids).delete_all
      self.model += deleted
      break if deleted < BATCH_SIZE
    end
  end

  private

  def expired_ids
    ApplyStep.where('finished_at < ?', RETENTION.ago).limit(BATCH_SIZE).select(:id)
  end
end
