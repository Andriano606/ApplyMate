# frozen_string_literal: true

# Session#wait_until: calls `condition` every POLL_MS until it returns a truthy value (the model) or
# min(timeout_ms, time left before the deadline) has passed (model false). A TargetNotFound or Playwright::Error
# raised by the condition counts as "not yet" (the page is re-rendering); anything else (Crashed, DeadlineExceeded,
# Obstructed) propagates. Termination: the budget check after every call.
class ApplyMate::Client::Browser::Operation::WaitUntil < ApplyMate::Operation::Base
  POLL_MS = 250

  def perform!(driver:, timeout_ms:, condition:, **)
    skip_authorize
    budget_ms = [ timeout_ms, driver.remaining_ms ].min
    started_at = clock.now_ms
    loop do
      value = attempt(condition)
      break self.model = value if value

      elapsed = clock.now_ms - started_at
      break self.model = false if elapsed >= budget_ms

      clock.sleep_ms((budget_ms - elapsed).clamp(1, POLL_MS))
    end
  end

  private

  def attempt(condition)
    condition.call
  rescue ApplyMate::Client::Browser::TargetNotFound, ::Playwright::Error
    false
  end

  def clock
    ApplyMate::Client::Browser::Clock
  end
end
