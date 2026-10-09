# frozen_string_literal: true

# Every step of the run succeeded: completed, submitted by the engine. An earlier submitted_at (written by the
# submit step itself) is kept.
class Apply::Operation::Engine::Lifecycle::Finish < Apply::Operation::Engine::Lifecycle::Base
  def perform!(ctx:, **)
    skip_authorize
    self.model = ctx.apply
    transition!(ctx, state: Apply.states.fetch(:completed), submitted_at: model.reload.submitted_at || Time.current,
                     submitted_via: 'engine', stage: nil, failure: nil)
    log("apply=#{model.hashid} attempt=#{ctx.attempt} completed", color: :green)
    broadcast(model)
  end
end
