# frozen_string_literal: true

# Daily (Apply::Job::PruneApplySteps) housekeeping of what every apply run leaves behind:
#   1. artifacts (masked screenshots, redacted HTML) of steps finished more than ARTIFACT_RETENTION ago are purged;
#   2. steps finished more than RETENTION ago are deleted, their attachments purged first;
#   3. step traces older than TRACE_RETENTION are nulled (the step row stays);
#   4. apply_host_slots idle for HOST_SLOT_RETENTION are deleted (one tiny row per throttled host).
# Steps ride index_apply_steps_on_finished_at (unfinished rows have NULL and never match), traces ride the partial
# index_apply_steps_prunable_trace. Applies themselves are never auto-deleted; deleting an apply removes its steps
# (dependent: :destroy). Bounded: BATCH_SIZE rows per statement, at most MAX_BATCHES per pass.
# model: deleted step row count.
class Apply::Operation::Engine::PruneApplySteps < ApplyMate::Operation::Base
  RETENTION = 180.days
  ARTIFACT_RETENTION = 30.days
  TRACE_RETENTION = 90.days
  HOST_SLOT_RETENTION = 1.day
  BATCH_SIZE = 1000
  MAX_BATCHES = 50

  def perform!(**)
    skip_authorize
    purge_old_artifacts
    self.model = delete_expired_steps
    null_old_traces
    # apply_host_slots holds one row per throttled tenant host, so the scan stays tiny.
    ApplyHostSlot.where('next_allowed_at < ?', HOST_SLOT_RETENTION.ago).delete_all
  end

  private

  def purge_old_artifacts
    ApplyStep.where('finished_at < ?', ARTIFACT_RETENTION.ago).joins(:artifacts_attachments).distinct
             .limit(BATCH_SIZE * MAX_BATCHES).find_each(batch_size: BATCH_SIZE) do |step|
      step.artifacts.each(&:purge_later)
    end
  end

  def delete_expired_steps
    total = 0
    MAX_BATCHES.times do
      ids = ApplyStep.where('finished_at < ?', RETENTION.ago).limit(BATCH_SIZE).pluck(:id)
      break if ids.empty?

      # Rides index_active_storage_attachments_uniqueness (record_type, record_id, ...).
      ActiveStorage::Attachment.where(record_type: 'ApplyStep', record_id: ids).find_each(&:purge_later)
      total += ApplyStep.where(id: ids).delete_all
      break if ids.size < BATCH_SIZE
    end
    total
  end

  def null_old_traces
    MAX_BATCHES.times do
      ids = ApplyStep.where('trace IS NOT NULL AND finished_at < ?', TRACE_RETENTION.ago).limit(BATCH_SIZE).select(:id)
      break if ApplyStep.where(id: ids).update_all(trace: nil) < BATCH_SIZE
    end
  end
end
