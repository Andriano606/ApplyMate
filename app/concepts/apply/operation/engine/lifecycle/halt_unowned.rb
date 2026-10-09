# frozen_string_literal: true

# Records a halt for an Apply no run owns: failures before the Runner started (handler resolution, job-level
# errors) and, in later phases, exhausted capacity retries. Writes only rows in queued / waiting_capacity
# (`WHERE state IN (0, 2)`, primary key), so a live run is never touched. The outcome comes from
# Lifecycle::Decide (claim rule included) with auto-resume disabled: the job itself failed, re-enqueueing it
# from here would loop. model: true when a row was updated.
class Apply::Operation::Engine::Lifecycle::HaltUnowned < Apply::Operation::Engine::Lifecycle::Base
  def perform!(apply_id:, code:, detail: nil, **)
    skip_authorize
    halt = Apply::Operation::Engine::Halt.new(code, detail:)
    apply = Apply.find_by(id: apply_id)
    self.model = apply.present? && record!(apply, halt) == 1
    notify(apply, halt) if model
  end

  private

  def record!(apply, halt)
    decision = Apply::Operation::Engine::Lifecycle::Decide.call(apply:, halt:, auto_resume: false).model
    Apply.where(id: apply.id, state: %i[queued waiting_capacity])
         .update_all(decision.attributes.merge(updated_at: Time.current))
  end

  def notify(apply, halt)
    log("apply=#{apply.hashid} attempt=#{apply.attempt} halt=#{halt.code} unowned")
    apply.touch_user_applies_changed_at!
    broadcast(apply)
  end
end
