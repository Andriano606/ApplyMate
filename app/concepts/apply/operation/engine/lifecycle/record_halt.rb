# frozen_string_literal: true

# Records a Halt for the run that owns the Apply (design §11.1): Lifecycle::Decide applies the claim rule and
# the auto-resume-once rule; this operation writes the Decision through ONE fenced UPDATE (a claim release is
# part of it), closes any step row of this attempt still marked running, broadcasts, and enqueues the
# auto-resume.
class Apply::Operation::Engine::Lifecycle::RecordHalt < Apply::Operation::Engine::Lifecycle::Base
  def perform!(ctx:, halt:, **)
    skip_authorize
    self.model = ctx.apply.reload # fresh claim, failure.auto_resumed and stage
    decision = Apply::Operation::Engine::Lifecycle::Decide.call(apply: model, halt:, stage: ctx.current_stage).model
    transition!(ctx, decision.attributes)
    Apply::Operation::Engine::CloseSteps.call(apply_id: model.id, attempts: ctx.attempt, code: halt.code)
    log("apply=#{model.hashid} attempt=#{ctx.attempt} halt=#{halt.code} state=#{decision.state} " \
        "auto_resume=#{decision.auto_resume}")
    broadcast(model)
    Apply::Operation::Engine::Enqueue.call(apply: model) if decision.auto_resume
  end
end
