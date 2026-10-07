# frozen_string_literal: true

# Closes apply_steps rows a run left `running` (design §11.1: no absorbing state). Only the Runner moves its own
# step rows to succeeded / failed; a run that died (OOM, container restart) or was fenced leaves its current row
# running, with finished_at NULL, which would spin in RunTimeline forever and never match PruneApplySteps.
# Whoever takes the row away from that run closes its rows:
#   - RecordHalt     attempts: ctx.attempt            (belt and braces: the Runner's fail_step normally did it)
#   - ReapStale      attempts: the reaped row's attempt, after the run_token rotation succeeded
#   - StartContext   attempts: ...new_attempt - 1      (takeover of a stale running row: earlier runs are fenced)
# Rows become failed with error_code = code and finished_at = now. Rides
# index_apply_steps_on_apply_id_and_attempt_and_key (apply_id, attempt prefix). model: closed row count.
class Apply::Operation::Engine::CloseSteps < ApplyMate::Operation::Base
  def perform!(apply_id:, attempts:, code:, **)
    skip_authorize
    now = Time.current
    self.model = ApplyStep.where(apply_id:, attempt: attempts, state: ApplyStep.states.fetch(:running))
                          .update_all(state: ApplyStep.states.fetch(:failed), error_code: code.to_s,
                                      finished_at: now, updated_at: now)
  end
end
