# frozen_string_literal: true

# One run of one Apply, built only by Apply::Operation::Engine::StartContext.
#
#   apply       Apply - the row this run owns (reloaded by the Runner/Lifecycle when they need fresh columns)
#   attempt     Integer - applies.attempt after the start UPDATE (apply_steps rows carry it)
#   run_token   String (uuid) - the fencing token; every engine write matches on it (FencedUpdate)
#   deadline_at Time - the run's wall-clock budget (Apply::RUN_DEADLINE after start)
#   fence_flag  Concurrent::AtomicBoolean - shared with the heartbeat thread, set once the run is fenced
#
# Immutable value: no DB writes here. Writes go through Apply::Operation::Engine::FencedUpdate.
Apply::Operation::Engine::Context = Data.define(:apply, :attempt, :run_token, :deadline_at, :fence_flag)

# Reopened (not `Data.define do … end`) so methods and docs read like a normal class.
class Apply::Operation::Engine::Context
  # Longest a single browser session may live; shorter than browserd's LEASE_TTL_S = 600, so the client
  # gives up (DeadlineExceeded) before browserd reaps the lease under it.
  SCOPE_DEADLINE = 8.minutes

  # Seconds left until deadline_at (negative once passed).
  def remaining
    deadline_at - Time.current
  end

  # The deadline a browser Session gets: its own budget, never past the run's deadline.
  def scope_deadline
    [ Time.current + SCOPE_DEADLINE, deadline_at ].min
  end

  def fenced?
    fence_flag.true?
  end

  def fence!
    fence_flag.make_true
  end

  def check_fence!
    raise Apply::Operation::Engine::Fenced, "apply=#{apply.id} run_token=#{run_token}" if fenced?
  end

  def current_stage
    apply.stage
  end
end
