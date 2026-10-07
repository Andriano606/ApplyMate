# frozen_string_literal: true

# The Runner (design §10.3): owns one run of one Apply.
#
#   StartContext (NotStartable -> log, write nothing)
#   Heartbeat ticker (shut down in ensure)
#   each handler step: condition (skip) -> fence check -> deadline -> stage write + ApplyStep row + broadcast
#                      -> step operation -> ApplyStep succeeded | failed (code + redacted detail)
#   Lifecycle::Finish, or Lifecycle::RecordHalt for a Halt / mapped exception
#   Fenced anywhere -> log, write nothing further
#
# Phase 1 runs every applicable step on every attempt: input digests / skip-with-restore and atomic session
# scopes arrive in phase 3a.
#
# apply_steps rows are not fenced: a row carries its run's attempt and no other run writes that attempt's rows.
class Apply::Operation::Engine::Run < ApplyMate::Operation::Base
  include ApplyMate::Logging

  # Exceptions a step may leak that have a dedicated failure code; anything else is unexpected_error.
  ERROR_CODES = {
    ApplyMate::Ai::Client::Base::EmptyResponse => :invalid_ai_output,
    ApplyMate::Ai::ResponseSchema::Json::InvalidResponse => :invalid_ai_output,
    ActiveRecord::RecordInvalid => :invalid_record
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
  rescue Apply::Operation::Engine::Halt => e
    Apply::Operation::Engine::Lifecycle::RecordHalt.call(ctx:, halt: e)
  rescue StandardError => e
    Rails.error.report(e, handled: true, context: { apply: ctx.apply.hashid, attempt: ctx.attempt })
    Apply::Operation::Engine::Lifecycle::RecordHalt.call(ctx:, halt: as_halt(e))
  end

  def run_plan(ctx, handler)
    handler.class.steps.each do |step|
      next if step.condition && !step.condition.call(ctx)

      run_step(ctx, handler, step)
    end
    Apply::Operation::Engine::Lifecycle::Finish.call(ctx:)
  end

  def run_step(ctx, handler, step)
    ctx.check_fence!
    raise Apply::Operation::Engine::Halt.new(:deadline) unless ctx.remaining.positive?

    record = start_step(ctx, step)
    result = step.operation.call(ctx:, handler:, **step.options)
    raise Apply::Operation::Engine::Halt.new(:invalid_record, detail: result.errors.full_messages.join('; ')) if result.failure?

    record.update!(state: :succeeded, finished_at: Time.current)
  rescue Apply::Operation::Engine::Fenced
    raise
  rescue StandardError => e
    fail_step(ctx, record, e)
    raise
  end

  def start_step(ctx, step)
    Apply::Operation::Engine::FencedUpdate.call(ctx:, attributes: { stage: step.operation.stage.to_s })
    log("apply=#{ctx.apply.hashid} step=#{step.key} attempt=#{ctx.attempt} started")
    record = ApplyStep.create!(apply: ctx.apply, attempt: ctx.attempt, key: step.key, stage: step.operation.stage.to_s,
                               position: step.position, state: :running, started_at: Time.current)
    Apply::Operation::Engine::Broadcast.call(apply: ctx.apply)
    record
  end

  def fail_step(ctx, record, error)
    return if record.nil?

    halt = as_halt(error)
    log("apply=#{ctx.apply.hashid} step=#{record.key} attempt=#{ctx.attempt} failed: #{halt.code}", level: :warn, color: :red)
    record.update!(state: :failed, finished_at: Time.current, error_code: halt.code.to_s,
                   error_detail: Apply::Operation::Engine::Redact.call(text: halt.detail, apply: ctx.apply).model)
  end

  def as_halt(error)
    return error if error.is_a?(Apply::Operation::Engine::Halt)

    code = ERROR_CODES.find { |klass, _| error.is_a?(klass) }&.last || :unexpected_error
    Apply::Operation::Engine::Halt.new(code, detail: "#{error.class}: #{error.message}")
  end
end
