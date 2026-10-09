# frozen_string_literal: true

# Politeness towards one tenant (design §11.6): at most one submit per platform throttle interval for the same
# throttle key (Ashby: per company slug; default: per form host). ONE statement both claims a free slot and moves
# next_allowed_at forward, so concurrent runs cannot both get it; the primary key conflict target rides
# apply_host_slots' primary key. The slot is free once next_allowed_at has passed OR when this apply already holds it
# (holder_apply_id): the step runs before the :submit scope opens its browser, so a PoolBusy, a halt before the claim
# (review, deadline, a gate) or any other failure of the scope would otherwise leave the apply throttled by its own
# reservation on the retry. Re-taking it restarts the interval from now (the submit happens now). A taken slot raises
# Throttled(until: next_allowed_at): the Runner parks the apply in waiting_capacity and Apply::Job::Apply retries the
# job at that time. Always runs (input_digest nil): a restored slot would defeat the throttle.
class Apply::Operation::Stage::AcquireHostSlot < Apply::Operation::Stage::Base
  stage :throttle

  SQL = <<~SQL.squish
    INSERT INTO apply_host_slots (host_key, next_allowed_at, holder_apply_id)
    VALUES ($1, now() + ($2 * interval '1 second'), $3)
    ON CONFLICT (host_key) DO UPDATE
    SET next_allowed_at = EXCLUDED.next_allowed_at, holder_apply_id = EXCLUDED.holder_apply_id
    WHERE apply_host_slots.next_allowed_at <= now() OR apply_host_slots.holder_apply_id = EXCLUDED.holder_apply_id
    RETURNING host_key
  SQL

  private

  def run!(ctx:, **)
    throttle = ctx.platform.class.throttle
    host_key = throttle[:key].call(ctx)
    if host_key.blank?
      ctx.trace(:throttle_skipped, reason: 'no key')
      return step_result(host_key: nil)
    end

    unless claim_slot(host_key, throttle[:interval], ctx.apply.id)
      wait_until = ApplyHostSlot.where(host_key:).pick(:next_allowed_at) || throttle[:interval].from_now
      ctx.trace(:throttled, host_key:, until: wait_until.iso8601)
      raise Apply::Operation::Engine::Throttled.new(until: wait_until)
    end

    ctx.trace(:slot_acquired, host_key:)
    step_result(host_key:)
  end

  def claim_slot(host_key, interval, apply_id)
    binds = [ ActiveRecord::Relation::QueryAttribute.new('host_key', host_key, ActiveRecord::Type::String.new),
              ActiveRecord::Relation::QueryAttribute.new('interval', interval.to_i, ActiveRecord::Type::Integer.new),
              ActiveRecord::Relation::QueryAttribute.new('holder_apply_id', apply_id, ActiveRecord::Type::Integer.new(limit: 8)) ]
    ApplyHostSlot.with_connection { |connection| connection.exec_query(SQL, 'Apply::AcquireHostSlot', binds).any? }
  end
end
