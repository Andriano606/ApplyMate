# frozen_string_literal: true

# Recurring sweep (Apply::Job::ReapStale, every minute, general queue): finds applies in queued / running /
# waiting_capacity whose heartbeat went stale and decides per row whether the job behind it is alive or lost
# (design §11.3). A lost run is closed in ONE UPDATE that also rotates run_token, so a zombie worker that wakes
# up later is fenced (FencedUpdate raises Fenced). What the halt does (claim rule, auto-resume once) is decided by
# Lifecycle::Decide, as for every other halt writer. Table in .ai/docs/apply_engine.md ("Reaper").
#
# Candidates ride index_applies_stale_candidates (COALESCE(heartbeat_at, updated_at) WHERE state IN (0, 1, 2)).
# Termination: a short or empty batch, or max_batches. Rows decided "alive" (or that raised) stay stale-looking,
# so their ids are excluded from the next batch (bounded by batch_size * max_batches) instead of being re-read.
# model: { reaped:, resumed:, alive: } counts.
class Apply::Operation::Engine::ReapStale < ApplyMate::Operation::Base
  include ApplyMate::Logging

  STALE_SQL = 'COALESCE(heartbeat_at, updated_at)'
  COLUMNS = %i[id user_id job_id deadline_at submit_claimed_at run_token failure state stage attempt].freeze
  # A claimed execution only counts as alive while its Solid Queue process heartbeats (default alive window).
  PROCESS_ALIVE_WITHIN = 5.minutes

  def perform!(batch_size: 100, max_batches: 10, **)
    skip_authorize
    self.model = { reaped: 0, resumed: 0, alive: 0 }
    skipped_ids = []
    max_batches.times do
      batch = candidates(batch_size, skipped_ids)
      batch.each { |apply| sweep(apply, skipped_ids) }
      break if batch.size < batch_size
    end
  end

  private

  def candidates(batch_size, skipped_ids)
    Apply.where(state: Apply::IN_PROGRESS_STATES)
         .where("#{STALE_SQL} < ?", Apply::STALE_AFTER.ago)
         .where.not(id: skipped_ids)
         .order(Arel.sql(STALE_SQL))
         .limit(batch_size)
         .select(*COLUMNS).to_a
  end

  def sweep(apply, skipped_ids)
    if alive?(apply)
      skipped_ids << apply.id
      model[:alive] += 1
    else
      reap(apply)
    end
  rescue StandardError => e
    skipped_ids << apply.id
    log("apply=#{apply.hashid} reap failed: #{e.class}: #{e.message}", level: :error)
    Rails.error.report(e, handled: true, context: { apply: apply.hashid })
  end

  # Alive: the job waits to run (ready / scheduled / blocked by limits_concurrency), or a live Solid Queue process
  # executes it and the run is within deadline + REAPER_GRACE. Anything else (no job, finished, failed_execution,
  # dead process, past the deadline) is lost.
  def alive?(apply)
    job = SolidQueue::Job.find_by(active_job_id: apply.job_id) if apply.job_id.present?
    return false if job.nil?
    return true if job.ready_execution || job.scheduled_execution || job.blocked_execution

    executing?(job) && within_deadline?(apply)
  end

  def executing?(job)
    last_beat = job.claimed_execution&.process&.last_heartbeat_at
    last_beat.present? && last_beat > PROCESS_ALIVE_WITHIN.ago
  end

  def within_deadline?(apply)
    apply.deadline_at.nil? || Time.current < apply.deadline_at + Apply::REAPER_GRACE
  end

  def reap(apply)
    halt = Apply::Operation::Engine::Halt.new(apply.deadline_at&.past? ? :deadline : :worker_lost)
    decision = Apply::Operation::Engine::Lifecycle::Decide.call(apply:, halt:, stage: apply.stage).model
    return unless write(apply, decision).positive?

    model[decision.auto_resume ? :resumed : :reaped] += 1
    Apply::Operation::Engine::CloseSteps.call(apply_id: apply.id, attempts: apply.attempt, code: halt.code)
    finish(apply, halt, decision)
  end

  # Not run-owned. Matches the run_token AND an in-progress state, so a run that finished (Finish / RecordHalt
  # keep run_token) or restarted (StartContext rotates it) between the SELECT and here makes this a no-op.
  def write(apply, decision)
    Apply.where(id: apply.id, run_token: apply.run_token, state: Apply::IN_PROGRESS_STATES)
         .update_all(decision.attributes.merge(run_token: SecureRandom.uuid, updated_at: Time.current))
  end

  def finish(apply, halt, decision)
    log("apply=#{apply.hashid} attempt=#{apply.attempt} halt=#{halt.code} reaped state=#{decision.state}")
    apply.touch_user_applies_changed_at!
    Apply::Operation::Engine::Broadcast.call(apply:)
    Apply::Operation::Engine::Enqueue.call(apply:) if decision.auto_resume
  end
end
