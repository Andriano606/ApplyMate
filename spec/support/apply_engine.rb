# frozen_string_literal: true

# Helpers for specs of Apply::Operation::Engine::* and of pipeline steps (included in every spec by
# spec/rails_helper.rb).
module ApplyEngineHelpers
  # A real run start (StartContext's UPDATE ... RETURNING, no stubs): the apply becomes running, attempt + 1,
  # fresh run_token. The apply must be startable (queued / waiting_capacity / running with a stale heartbeat).
  def engine_context(apply)
    Apply::Operation::Engine::StartContext.call(apply:).model
  end

  # Runs `operation` as the only step of a one-off handler through the real Runner (StartContext, ApplyStep rows,
  # claim rule, Lifecycle) and returns the reloaded apply. `options` are the step's add_step options. Yields the
  # handler instance first, e.g. to stub `build_payload` on it.
  def run_engine_step(apply, operation, **options)
    handler = Class.new(Apply::Handler::Base) { add_step(operation, **options) }.new(apply:)
    yield handler if block_given?
    handler.call
    apply.reload
  end

  # Rotates run_token the way a newer StartContext does, leaving `ctx` a zombie.
  def rotate_run_token!(apply)
    Apply.where(id: apply.id).update_all(run_token: SecureRandom.uuid)
  end
end
