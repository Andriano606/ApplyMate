# frozen_string_literal: true

# The Runner (design §10.3): owns one run of one Apply.
#
#   StartContext (NotStartable -> log, write nothing)
#   Heartbeat ticker (shut down in ensure)
#   units of the handler's steps: consecutive steps of one session_scope form a unit, a scope-less step is its own
#   scope unit: condition falsy -> no rows; skippable (every step has a succeeded row of one earlier attempt with the
#   same input digest) -> `restore`, no rows; otherwise the whole scope runs inside ONE browser Session
#   each step: condition (skip) -> fence check -> deadline -> stage write + ApplyStep row + broadcast
#              -> step operation -> ApplyStep succeeded | failed (code + redacted detail), result and trace stored
#   Lifecycle::Finish, or Lifecycle::RecordHalt for a Halt / mapped exception
#   Fenced anywhere -> log, write nothing further
#
# A scope-less step with an input digest (Stage::Base) is skipped on its own when a succeeded row with that digest
# exists; scope-less steps without a digest (the legacy pipeline) run every attempt.
#
# apply_steps rows are not fenced: a row carries its run's attempt and no other run writes that attempt's rows.
class Apply::Operation::Engine::Run < ApplyMate::Operation::Base
  include ApplyMate::Logging

  # Exceptions a step may leak that have a dedicated failure code; anything else is unexpected_error.
  ERROR_CODES = {
    ApplyMate::Ai::Client::Base::EmptyResponse => :invalid_ai_output,
    ApplyMate::Ai::ResponseSchema::Json::InvalidResponse => :invalid_ai_output,
    ActiveRecord::RecordInvalid => :invalid_record,
    ApplyMate::Client::Browser::PoolBusy => :capacity,
    Apply::Operation::Engine::Throttled => :capacity,
    ApplyMate::Client::Browser::Crashed => :browser_crashed,
    ApplyMate::Client::Browser::DeadlineExceeded => :deadline,
    ApplyMate::Client::Browser::TargetNotFound => :target_not_found,
    ApplyMate::Client::Browser::Obstructed => :target_obstructed,
    # Deliberately unexpected_error: a gem/browserd version mismatch is permanent until the deploy is fixed.
    ApplyMate::Client::Browser::VersionMismatch => :unexpected_error,
    ApplyMate::Net::UnsafeUrlError => :private_address
  }.freeze

  def perform!(apply:, handler:, **)
    skip_authorize
    self.model = apply
    supervise(Apply::Operation::Engine::StartContext.call(apply:).model, handler)
  rescue Apply::Operation::Engine::NotStartable, Apply::Operation::Engine::Fenced => e
    log("apply=#{apply.hashid} runner skipped: #{e.class}: #{e.message}")
  end

  private

  def supervise(ctx, handler)
    ticker = Apply::Operation::Engine::Heartbeat.call(ctx:).model
    execute(ctx, handler)
  ensure
    ticker&.shutdown
  end

  def execute(ctx, handler)
    run_plan(ctx, handler)
  rescue Apply::Operation::Engine::Fenced
    raise
  rescue ApplyMate::Client::Browser::PoolBusy, Apply::Operation::Engine::Throttled
    # No free browser slot / tenant host slot: park the row and let the job retry (Apply::Job::Apply retry_on,
    # rescue_from Throttled) instead of failing.
    Apply::Operation::Engine::Lifecycle::WaitCapacity.call(ctx:)
    raise
  rescue Apply::Operation::Engine::Halt => e
    Apply::Operation::Engine::Lifecycle::RecordHalt.call(ctx:, halt: e)
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { apply: ctx.apply.hashid, attempt: ctx.attempt })
    Apply::Operation::Engine::Lifecycle::RecordHalt.call(ctx:, halt: as_halt(e))
  end

  def run_plan(ctx, handler)
    units(handler.class.steps).each do |scope, steps|
      scope ? run_scope(ctx, handler, scope, steps) : steps.each { |step| run_step(ctx, handler, step, skippable: true) }
    end
    Apply::Operation::Engine::Lifecycle::Finish.call(ctx:)
  end

  # [[scope or nil, [steps]], ...]: a scope-less step is a unit of its own, consecutive steps of one scope share one.
  def units(steps)
    steps.chunk_while { |previous, step| previous.scope && previous.scope == step.scope }
         .map { |chunk| [ chunk.first.scope, chunk ] }
  end

  def run_scope(ctx, handler, scope, steps)
    condition = handler.class.scope_conditions[scope]
    return if condition && !condition.call(ctx)

    active = steps.select { |step| step.condition.nil? || step.condition.call(ctx) }
    return if active.empty? || restored_scope?(ctx, scope, active)

    ctx.check_fence!
    raise Apply::Operation::Engine::Halt.new(:deadline) unless ctx.remaining.positive?

    in_session(ctx, scope) { steps.each { |step| run_step(ctx, handler, step, skippable: false) } }
  end

  # One browser lease for the whole scope; the submit scope types humanlike. close_scope! also runs when Session.open
  # failed before yielding.
  def in_session(ctx, scope)
    deadline = ctx.scope_deadline
    ApplyMate::Client::Browser::Session.open(deadline:, owner: ApplyMate::Client::Browser::Session.owner_for(ctx.apply),
                                             humanize: scope == :submit, identity: ctx.apply.hashid) do |session|
      ctx.open_scope!(scope, session, deadline)
      yield
    end
  ensure
    ctx.close_scope!
  end

  # True when EVERY step of the scope has a succeeded row (same key + digest) and all those rows come from one
  # attempt: the scope as a whole ran before and is restored without a browser. Steps are restored as the lookup
  # goes (a later digest may read what an earlier restore rebuilt); a scope that then runs overwrites that state.
  def restored_scope?(ctx, scope, steps)
    rows = []
    steps.each do |step|
      row = resumable_row(ctx, step)
      return false if row.nil? || (rows.any? && rows.first.attempt != row.attempt)

      step.operation.restore(ctx, row.result || {})
      rows << row
    end
    log("apply=#{ctx.apply.hashid} scope=#{scope} attempt=#{ctx.attempt} skipped (restore)")
    true
  end

  def run_step(ctx, handler, step, skippable:)
    return if step.condition && !step.condition.call(ctx)

    if skippable && (row = resumable_row(ctx, step))
      step.operation.restore(ctx, row.result || {})
      log("apply=#{ctx.apply.hashid} step=#{step.key} attempt=#{ctx.attempt} skipped (restore)")
      return
    end

    execute_step(ctx, handler, step)
  end

  # The newest succeeded row of this apply with the step's key and current input digest (any earlier attempt), or
  # nil for a step without a digest. Rides index_apply_steps_resume_lookup.
  def resumable_row(ctx, step)
    digest = input_digest(ctx, step)
    return if digest.nil?

    ApplyStep.where(apply_id: ctx.apply.id, key: step.key, input_digest: digest, state: :succeeded).order(:attempt).last
  end

  def input_digest(ctx, step)
    return unless step.operation.respond_to?(:input_digest)

    step.operation.input_digest(ctx, **step.options)
  end

  def execute_step(ctx, handler, step)
    ctx.check_fence!
    raise Apply::Operation::Engine::Halt.new(:deadline) unless ctx.remaining.positive?

    record = start_step(ctx, step)
    ctx.scratch.step_record = record
    result = step.operation.call(ctx:, handler:, **step.options)
    raise Apply::Operation::Engine::Halt.new(:invalid_record, detail: result.errors.full_messages.join('; ')) if result.failure?

    finish_step(ctx, record, result)
  rescue Apply::Operation::Engine::Fenced
    raise
  rescue StandardError => e
    fail_step(ctx, record, e)
    raise
  ensure
    ctx.scratch.step_record = nil
  end

  def start_step(ctx, step)
    Apply::Operation::Engine::FencedUpdate.call(ctx:, attributes: { stage: step.operation.stage.to_s })
    log("apply=#{ctx.apply.hashid} step=#{step.key} attempt=#{ctx.attempt} started")
    record = ApplyStep.create!(apply: ctx.apply, attempt: ctx.attempt, key: step.key, stage: step.operation.stage.to_s,
                               position: step.position, scope: step.scope&.to_s, input_digest: input_digest(ctx, step),
                               state: :running, started_at: Time.current)
    Apply::Operation::Engine::Broadcast.call(apply: ctx.apply)
    record
  end

  def finish_step(ctx, record, result)
    record.update!(state: :succeeded, finished_at: Time.current, result: redact_tree(ctx, result[:step_result]),
                   trace: redact_tree(ctx, ctx.flush_trace!.presence))
  end

  # The failure evidence is taken while the scope's session is still open, before the row is closed.
  def fail_step(ctx, record, error)
    return if record.nil?

    halt = as_halt(error)
    log("apply=#{ctx.apply.hashid} step=#{record.key} attempt=#{ctx.attempt} failed: #{halt.code}", level: :warn, color: :red)
    Apply::Operation::Engine::CaptureArtifact.call(ctx:, step_record: record, label: :failure)
    record.update!(state: :failed, finished_at: Time.current, error_code: halt.code.to_s,
                   error_detail: Apply::Operation::Engine::Redact.call(text: halt.detail, apply: ctx.apply).model,
                   trace: redact_tree(ctx, ctx.flush_trace!.presence))
  end

  def redact_tree(ctx, value)
    Apply::Operation::Engine::RedactTree.call(value:, apply: ctx.apply).model
  end

  def as_halt(error)
    return error if error.is_a?(Apply::Operation::Engine::Halt)

    code = ERROR_CODES.find { |klass, _| error.is_a?(klass) }&.last || :unexpected_error
    Apply::Operation::Engine::Halt.new(code, detail: "#{error.class}: #{error.message}")
  end
end
