# frozen_string_literal: true

# Takes ownership of an Apply for one run in a single UPDATE ... RETURNING (design §10.3):
# state -> running, attempt + 1, a fresh run_token, deadline_at = now + Apply::RUN_DEADLINE, heartbeat now.
#
# Startable rows: queued / waiting_capacity, or running with a heartbeat older than Apply::STALE_AFTER
# (a redelivered job after a deploy/crash). A live run (fresh heartbeat) or any other state matches no row
# and raises NotStartable, so a second job never starts on top of a live run. The UPDATE rides the primary key.
# ai_calls = 0 joins this statement with AiBudget (phase 3a).
class Apply::Operation::Engine::StartContext < ApplyMate::Operation::Base
  SQL = <<~SQL.squish
    UPDATE applies
       SET state = $2, attempt = attempt + 1, run_token = gen_random_uuid(),
           deadline_at = now() + ($3 * interval '1 second'), heartbeat_at = now(), stage = NULL, updated_at = now()
     WHERE id = $1
       AND (state IN ($4, $5)
            OR (state = $2 AND COALESCE(heartbeat_at, updated_at) < now() - ($6 * interval '1 second')))
    RETURNING attempt, run_token, deadline_at
  SQL

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
    [ [ 'id', apply.id ], [ 'running', Apply.states[:running] ], [ 'deadline', Apply::RUN_DEADLINE.to_i ],
      [ 'queued', Apply.states[:queued] ], [ 'waiting_capacity', Apply.states[:waiting_capacity] ],
      [ 'stale_after', Apply::STALE_AFTER.to_i ] ].map do |name, value|
      ActiveRecord::Relation::QueryAttribute.new(name, value, integer)
    end
  end
end
