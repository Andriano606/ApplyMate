# frozen_string_literal: true

# Puts an Apply's run on the apply queue and remembers the ActiveJob id (applies.job_id) for the reaper.
# A plain write, not fenced: the row is queued, so no run owns it.
class Apply::Operation::Engine::Enqueue < ApplyMate::Operation::Base
  def perform!(apply:, **)
    skip_authorize
    self.model = Apply::Job::Apply.perform_later(apply.id)
    Apply.where(id: apply.id).update_all(job_id: model.job_id, updated_at: Time.current)
  end
end
