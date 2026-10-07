# frozen_string_literal: true

# Starts the run's heartbeat: a Concurrent::TimerTask that runs Heartbeat::Tick every INTERVAL seconds on
# its own thread, independent of blocking browser/AI calls on the job thread. The Runner owns the task and
# calls #shutdown in its ensure.
#
# DB pool: every apply-worker thread adds one ticker connection while its run is live, so the apply worker's
# primary pool must be >= 2 * APPLY_SLOTS + 2 (Apply::Operation::AssertQueueTopology checks it at boot; see
# .ai/docs/apply_engine.md, "Heartbeat").
class Apply::Operation::Engine::Heartbeat < ApplyMate::Operation::Base
  INTERVAL = 30 # seconds; Apply::STALE_AFTER (3 min) tolerates several missed ticks

  def perform!(ctx:, **)
    skip_authorize
    self.model = Concurrent::TimerTask.new(execution_interval: INTERVAL, run_now: false) { tick(ctx) }.tap(&:execute)
  end

  private

  # TimerTask swallows exceptions; the executor wrap reports them to Rails.error (DB down, pool checkout timeout),
  # so a missed beat is visible instead of silent.
  def tick(ctx)
    Rails.application.executor.wrap do
      ActiveRecord::Base.connection_pool.with_connection { Apply::Operation::Engine::Heartbeat::Tick.call(ctx:) }
    end
  end
end
