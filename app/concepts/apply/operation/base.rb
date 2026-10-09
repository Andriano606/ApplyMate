# frozen_string_literal: true

# A pipeline step, run by Apply::Operation::Engine::Run (the Runner) for each `add_step` of a handler.
#
# Every step declares its stage (`stage :fetch_details`): the Runner writes it to applies.stage while the step
# runs and uses it as the apply_steps key. The step does its work in `run!(apply:, handler:, ctx:, **options)`
# and signals an outcome by raising Apply::Operation::Engine::Halt (or any exception, mapped by the Runner).
# Lifecycle state, failure, step rows and broadcasts belong to the Runner, never to the step.
class Apply::Operation::Base < ApplyMate::Operation::Base
  class << self
    def stage(key = nil)
      @stage = key if key
      @stage || raise(NotImplementedError, "#{name} must declare stage")
    end
  end

  def perform!(ctx:, handler: nil, **options)
    skip_authorize
    self.model = ctx.apply
    run!(apply: ctx.apply, handler:, ctx:, **options)
  ensure
    run_cleanup
  end

  private

  # A failing cleanup (browser quit) must neither fail a finished step nor replace the step's own exception.
  def run_cleanup
    cleanup
  rescue StandardError => e
    Rails.logger.error("#{self.class} cleanup failed: #{e.class}: #{e.message}")
  end

  def run!(apply:, handler:, **)
    raise NotImplementedError, "#{self.class} must define run!"
  end

  # Stops the run with a Halt code (Apply::Operation::Engine::Halt::CODES); the Runner records it. `detail` is
  # admin-only and redacted before it is stored; `definitive: true` only with deterministic proof that a claimed
  # submit was not accepted (see .ai/docs/apply_engine.md, "Claim rule").
  def halt!(code, detail: nil, definitive: false)
    raise Apply::Operation::Engine::Halt.new(code, detail:, definitive:)
  end

  def cleanup; end
end
