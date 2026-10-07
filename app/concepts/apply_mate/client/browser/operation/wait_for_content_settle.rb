# Port of the attached runtime's waitForContentSettle: poll the total visible text length across all frames every
# POLL_MS until it is non-zero and unchanged twice in a row. model = true when settled, false at the budget.
# Termination: bounded by min(max_ms, time left before the deadline).
class ApplyMate::Client::Browser::Operation::WaitForContentSettle < ApplyMate::Operation::Base
  POLL_MS = 500
  STABLE_POLLS = 2
  TEXT_LENGTH_JS = '() => (document.body ? document.body.innerText.length : 0)'.freeze

  def perform!(driver:, max_ms: 9_000, **)
    skip_authorize
    self.model = settle(driver, [ max_ms, driver.remaining_ms ].min)
  end

  private

  def settle(driver, budget_ms)
    started_at = clock.now_ms
    previous = -1
    stable = 0
    while clock.now_ms - started_at < budget_ms
      total = driver.frames.sum { |frame| text_length(driver, frame) }
      stable = total.positive? && total == previous ? stable + 1 : 0
      return true if stable >= STABLE_POLLS

      previous = total
      clock.sleep_ms(POLL_MS)
    end
    false
  end

  # A detached or cross-process frame that cannot be evaluated counts as empty (as onError: () => 0 in the JS).
  def text_length(driver, frame)
    driver.evaluate(frame, TEXT_LENGTH_JS).to_i
  rescue ::Playwright::Error
    0
  end

  def clock
    ApplyMate::Client::Browser::Clock
  end
end
