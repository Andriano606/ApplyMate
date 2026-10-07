# Polls until the element `target` points to (usually a form root) exists and contains at least `min_fields`
# visible fillable controls (probe readiness.js). model = true when ready, false at the timeout.
# Termination: polls every POLL_MS until min(timeout_ms, time left before the deadline). A root that matches
# several elements (TargetNotFound#ambiguous?, e.g. `form` on a page with a search form) ends the wait at once
# with false: the target is too broad, and polling would only burn the deadline on an answer that cannot change.
class ApplyMate::Client::Browser::Operation::WaitReady < ApplyMate::Operation::Base
  POLL_MS = 250

  def perform!(driver:, target:, timeout_ms:, min_fields: 1, **)
    skip_authorize
    budget_ms = [ timeout_ms, driver.remaining_ms ].min
    started_at = clock.now_ms
    loop do
      state = readiness(driver, target, min_fields)
      break self.model = (state == :ready) unless state == :pending
      break self.model = false if clock.now_ms - started_at >= budget_ms

      clock.sleep_ms(POLL_MS)
    end
  end

  private

  # :ready, :ambiguous, or :pending (not rendered yet, or replaced while probing).
  def readiness(driver, target, min_fields)
    root = ApplyMate::Client::Browser::Operation::Locate.call(driver:, target:, visibility: :attached).model
    driver.probe(:readiness, root, { 'min' => min_fields })['ready'] ? :ready : :pending
  rescue ApplyMate::Client::Browser::TargetNotFound => e
    e.ambiguous? ? :ambiguous : :pending
  rescue ::Playwright::Error
    :pending
  end

  def clock
    ApplyMate::Client::Browser::Clock
  end
end
