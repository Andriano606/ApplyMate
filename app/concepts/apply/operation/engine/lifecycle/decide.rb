# frozen_string_literal: true

# The single owner of "what does this Halt do to this Apply" (design §11.1). Every writer of a halt state —
# RecordHalt (the owning run), ReapStale (lost run), HaltUnowned (no run), ExpireWaiting (waited too long) —
# asks Decide and writes the Decision; none of them recomputes the rules.
#
# Claim rule: once submit_claimed_at is set, every halt lands in submit_unverified (the code is kept for
# display), except a definitive rejection (Halt#releases_claim?), which releases the claim (the caller clears
# submit_claimed_at in the same UPDATE) and takes the halt's own state.
#
# Auto-resume: a transient halt before the claim re-queues the Apply once per Apply (failure.auto_resumed,
# carried over by every later failure). The second transient halt stays failed and waits for the user (Resume).
# `auto_resume: false` disables it for writers that must not enqueue (HaltUnowned: the job itself failed).
#
# Failure shape (every writer): { code, kind, stage, detail (redacted), after_claim, attempt, auto_resumed? }
# plus the writer's `extra` keys (ExpireWaiting: expired_at, previous).
#
# `apply` needs failure, attempt and submit_claimed_at loaded; source_profile/user only when `detail` is present
# (Redact). model: Decision.
class Apply::Operation::Engine::Lifecycle::Decide < ApplyMate::Operation::Base
  Decision = Data.define(:state, :auto_resume, :release_claim, :failure) do
    # Attributes for the UPDATE that records the decision (state as the enum integer).
    def attributes
      attributes = { state: Apply.states.fetch(state), failure:, stage: nil }
      attributes[:submit_claimed_at] = nil if release_claim
      attributes
    end
  end

  def perform!(apply:, halt:, stage: nil, auto_resume: true, extra: {}, **)
    skip_authorize
    claimed = apply.claimed?
    previously = apply.failure_info[:auto_resumed] == true
    release = claimed && halt.releases_claim?
    resume = auto_resume && halt.kind == :transient && !claimed && !previously
    self.model = Decision.new(state: target_state(halt, claimed, release, resume), auto_resume: resume,
                              release_claim: release,
                              failure: failure(apply, halt, stage, claimed, resume || previously).merge(extra))
  end

  private

  def target_state(halt, claimed, release, resume)
    return :queued if resume
    return :submit_unverified if claimed && !release

    halt.state
  end

  def failure(apply, halt, stage, claimed, auto_resumed)
    detail = Apply::Operation::Engine::Redact.call(text: halt.detail, apply:).model
    failure = { code: halt.code, kind: halt.kind, stage:, detail:, after_claim: claimed, attempt: apply.attempt }
    failure[:auto_resumed] = true if auto_resumed
    failure
  end
end
