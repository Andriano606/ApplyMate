# frozen_string_literal: true

# One heartbeat: heartbeat_at = now, fenced, and only while now() < deadline_at + Apply::HEARTBEAT_GRACE.
# Past that the heartbeat stops on purpose so the reaper takes the hung run over; the run fences itself.
# Never raises out of the timer thread: model true on a written beat, false once fenced.
class Apply::Operation::Engine::Heartbeat::Tick < ApplyMate::Operation::Base
  def perform!(ctx:, **)
    skip_authorize
    self.model = beat(ctx)
  rescue Apply::Operation::Engine::Fenced
    self.model = false
  end

  private

  def beat(ctx)
    rows = Apply::Operation::Engine::FencedUpdate.call(ctx:, attributes: { heartbeat_at: Time.current },
                                                       extra_condition: within_grace).model
    return true if rows.positive?

    ctx.fence!
    false
  end

  def within_grace
    "now() < deadline_at + interval '#{Apply::HEARTBEAT_GRACE.to_i} seconds'"
  end
end
