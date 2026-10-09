# frozen_string_literal: true

# Hourly (Apply::Job::ExpireWaiting): applies that wait for a person (Apply::WAITING_STATES) are reminded, then
# closed (design §11.3). "Waiting since" is updated_at: every transition bumps it, the reminder write does not.
#
# 1. Expire: needs_human older than HUMAN_TIMEOUT -> failed(:human_timeout); needs_review older than
#    REVIEW_TIMEOUT -> failed(:review_expired) (Apply::WAIT_TIMEOUTS; needs_review has no producer before phase
#    3a). The outcome comes from Lifecycle::Decide like every other halt (a claimed row would land in
#    submit_unverified); the previous failure is kept under failure.previous. Rides index_applies_waiting_updated.
# 2. Remind: rows waiting longer than REMIND_AFTER (48 h) whose current wait has no reminder yet
#    (Apply::REMINDER_DUE_SQL, index_applies_remind_candidates) get reminded_at = now, a counter-key touch and a
#    broadcast: the card shows the reminder with the closing date (FailureNotice). The in-app card and the
#    navbar counter are the only channel (no mailer is configured).
#
# Not run-owned (nobody runs a waiting apply): both UPDATEs match state (and the reminder also updated_at), so a
# user action in between wins. Bounded: batch_size rows per expiry state and batch_size reminders per run; the
# hourly schedule drains any backlog. model: { human_timeout:, review_expired:, reminded: } counts.
class Apply::Operation::Engine::ExpireWaiting < ApplyMate::Operation::Base
  include ApplyMate::Logging

  EXPIRY_CODES = { 'needs_human' => :human_timeout, 'needs_review' => :review_expired }.freeze

  def perform!(batch_size: 100, **)
    skip_authorize
    self.model = EXPIRY_CODES.to_h { |state, code| [ code, expire(state, code, batch_size) ] }
    model[:reminded] = remind(batch_size)
  end

  private

  def expire(state, code, batch_size)
    Apply.where(state:).where('updated_at < ?', Apply::WAIT_TIMEOUTS.fetch(state).ago)
         .order(:updated_at).limit(batch_size).count { |apply| guarded(apply) { expire_one(apply, state, code) } }
  end

  def remind(batch_size)
    Apply.where(state: Apply::WAITING_STATES).where(Apply::REMINDER_DUE_SQL)
         .where('updated_at < ?', Apply::REMIND_AFTER.ago)
         .order(:updated_at).limit(batch_size).count { |apply| guarded(apply) { remind_one(apply) } }
  end

  def expire_one(apply, state, code)
    halt = Apply::Operation::Engine::Halt.new(code)
    decision = Apply::Operation::Engine::Lifecycle::Decide.call(
      apply:, halt:, extra: { expired_at: Time.current.iso8601, previous: apply.failure }
    ).model
    return false unless Apply.where(id: apply.id, state:)
                             .update_all(decision.attributes.merge(updated_at: Time.current)).positive?

    notify(apply, "expired from #{state} code=#{halt.code} state=#{decision.state}")
  end

  # Leaves updated_at alone: it is the "waiting since" clock for both the expiry and the next reminder.
  def remind_one(apply)
    return false unless Apply.where(id: apply.id, state: apply.state, updated_at: apply.updated_at)
                             .update_all(reminded_at: Time.current).positive?

    notify(apply, "reminded in #{apply.state}")
  end

  def notify(apply, message)
    log("apply=#{apply.hashid} #{message}")
    apply.touch_user_applies_changed_at!
    Apply::Operation::Engine::Broadcast.call(apply:)
    true
  end

  def guarded(apply)
    yield
  rescue StandardError => e
    log("apply=#{apply.hashid} expire_waiting failed: #{e.class}: #{e.message}", level: :error)
    Rails.error.report(e, handled: true, context: { apply: apply.hashid })
    false
  end
end
