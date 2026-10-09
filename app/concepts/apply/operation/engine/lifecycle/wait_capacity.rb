# frozen_string_literal: true

# The owning run found no free browser slot (PoolBusy): park the row in waiting_capacity (stage cleared,
# `failure` untouched) and close the run's open step rows with :capacity. The job then retries
# (Apply::Job::Apply retry_on); StartContext takes a waiting_capacity row again, and HaltUnowned turns an
# exhausted retry budget into failed(:capacity). Fenced like every owned transition; FencedUpdate touches
# users.applies_changed_at because the state changes.
class Apply::Operation::Engine::Lifecycle::WaitCapacity < Apply::Operation::Engine::Lifecycle::Base
  def perform!(ctx:, **)
    skip_authorize
    self.model = ctx.apply.reload
    transition!(ctx, { state: Apply.states.fetch('waiting_capacity'), stage: nil })
    Apply::Operation::Engine::CloseSteps.call(apply_id: model.id, attempts: ctx.attempt, code: :capacity)
    log("apply=#{model.hashid} attempt=#{ctx.attempt} waiting_capacity")
    broadcast(model)
  end
end
