# frozen_string_literal: true

# Takes ownership of an Apply for one run in a single UPDATE ... RETURNING (design §10.3):
# state -> running, attempt + 1, a fresh run_token, deadline_at = now + run_seconds, heartbeat now.
# run_seconds = Apply::RUN_DEADLINE plus the slow-AI allowance for Context::RUN_AI_CALLS calls (CallAi.allowance: 0 for an
# API integration, 8 * 180 s for GeminiScraping); Apply::Job::Apply's concurrency window covers the largest one.
#
# Startable rows: queued / waiting_capacity, or running with a heartbeat older than Apply::STALE_AFTER
# (a redelivered job after a deploy/crash). A live run (fresh heartbeat) or any other state matches no row
# and raises NotStartable, so a second job never starts on top of a live run. The UPDATE rides the primary key.
# ai_calls = 0 resets the per-attempt AI budget (CallAi); ai_calls_total is never reset. input_request / input_response
# are cleared so a resumed run never consumes a stale code (Engine::AwaitInput).
class Apply::Operation::Engine::StartContext < ApplyMate::Operation::Base
  SQL = <<~SQL.squish
    UPDATE applies
       SET state = $2, attempt = attempt + 1, run_token = gen_random_uuid(),
           deadline_at = now() + ($3 * interval '1 second'), heartbeat_at = now(), stage = NULL, ai_calls = 0,
           input_request = NULL, input_response = NULL, updated_at = now()
     WHERE id = $1
       AND (state IN ($4, $5)
            OR (state = $2 AND COALESCE(heartbeat_at, updated_at) < now() - ($6 * interval '1 second')))
    RETURNING attempt, run_token, deadline_at
  SQL

  def self.run_seconds(ai_integration)
    Apply::RUN_DEADLINE.to_i +
      Apply::Operation::Engine::CallAi.allowance(ai_integration, Apply::Operation::Engine::Context::RUN_AI_CALLS)
  end

  # The longest run_seconds any integration gets.
  def self.max_run_seconds
    Apply::RUN_DEADLINE.to_i + Apply::Operation::Engine::CallAi.max_allowance(Apply::Operation::Engine::Context::RUN_AI_CALLS)
  end

  def perform!(apply:, **)
    skip_authorize
    raise Apply::Operation::Engine::NotStartable, "apply=#{apply.id} state=#{apply.state}" if claim_row(apply).empty?

    apply.reload
    # A takeover of a stale running row: the earlier run is fenced now and will never close its step rows.
    Apply::Operation::Engine::CloseSteps.call(apply_id: apply.id, attempts: ...apply.attempt, code: :worker_lost)
    self.model = Apply::Operation::Engine::Context.new(apply:, attempt: apply.attempt, run_token: apply.run_token,
                                                       deadline_at: apply.deadline_at,
                                                       fence_flag: Concurrent::AtomicBoolean.new(false))
  end

  private

  def claim_row(apply)
    Apply.with_connection { |connection| connection.exec_query(SQL, 'Apply::StartContext', binds(apply)) }
  end

  def binds(apply)
    integer = ActiveRecord::Type::Integer.new
    [ [ 'id', apply.id ], [ 'running', Apply.states[:running] ], [ 'deadline', self.class.run_seconds(apply.ai_integration) ],
      [ 'queued', Apply.states[:queued] ], [ 'waiting_capacity', Apply.states[:waiting_capacity] ],
      [ 'stale_after', Apply::STALE_AFTER.to_i ] ].map do |name, value|
      ActiveRecord::Relation::QueryAttribute.new(name, value, integer)
    end
  end
end
