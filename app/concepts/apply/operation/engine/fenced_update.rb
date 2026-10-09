# frozen_string_literal: true

# The single fenced write to `applies` (Lifecycle, ClaimSubmit, Runner stage writes, Heartbeat::Tick).
# Matches `id AND run_token` (primary key), so a run whose token was rotated by a newer StartContext (zombie)
# writes nothing: 0 rows -> ctx.fence! and Fenced.
#
# extra_condition (trusted SQL fragment, never user input) narrows the write further (ClaimSubmit: no claim
# yet; Tick: before deadline + grace). When only the extra condition failed and the run still owns the row,
# the model is 0 and nothing is raised: the caller decides what that means.
#
# A write that changes `state` touches users.applies_changed_at (navbar attention counter cache key).
class Apply::Operation::Engine::FencedUpdate < ApplyMate::Operation::Base
  def perform!(ctx:, attributes:, extra_condition: nil, **)
    skip_authorize
    ctx.check_fence!
    self.model = owned(ctx).then { |scope| extra_condition ? scope.where(extra_condition) : scope }
                           .update_all(attributes.merge(updated_at: Time.current))
    return touch_user(ctx, attributes) if model.positive?

    fence!(ctx) unless extra_condition && owned(ctx).exists?
  end

  private

  def owned(ctx)
    Apply.where(id: ctx.apply.id, run_token: ctx.run_token)
  end

  def touch_user(ctx, attributes)
    ctx.apply.touch_user_applies_changed_at! if attributes.key?(:state)
  end

  def fence!(ctx)
    ctx.fence!
    raise Apply::Operation::Engine::Fenced, "apply=#{ctx.apply.id} run_token=#{ctx.run_token}"
  end
end
