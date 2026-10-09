# Port of the attached runtime's waitQuiet: after an action, wait until the page's network is quiet.
# Returns once at least `min` ms passed, nothing younger than IGNORE_OLDER_MS is in flight and the last network
# event is `quiet` ms old; gives up at `max` ms. model = { quiet: Boolean, ms: elapsed }.
#
# Termination: every poll sleeps >= 1 ms and the loop ends at `max`, which is clamped to the time left before
# `deadline` (no time left -> returns { quiet: false } at once; the next driver primitive raises DeadlineExceeded).
class ApplyMate::Client::Browser::Operation::WaitQuiet < ApplyMate::Operation::Base
  # profile => [min, quiet, max] in ms (design §9.1, attached SETTLE_* plus submit)
  PROFILES = {
    click: [ 150, 300, 2_500 ],
    key: [ 50, 200, 1_500 ],
    file: [ 300, 500, 8_000 ],
    submit: [ 500, 1_000, 15_000 ]
  }.freeze
  IGNORE_OLDER_MS = 3_000
  POLL_MS = 50

  def perform!(tracker:, profile:, deadline:, **)
    skip_authorize
    min_ms, quiet_ms, max_ms = PROFILES.fetch(profile)
    max_ms = [ max_ms, clock.remaining_ms(deadline) ].min
    self.model = wait(tracker, min_ms, quiet_ms, max_ms)
  end

  private

  def wait(tracker, min_ms, quiet_ms, max_ms)
    started_at = clock.now_ms
    loop do
      now = clock.now_ms
      elapsed = now - started_at
      return { quiet: true, ms: elapsed } if elapsed >= min_ms && quiet?(tracker, now, quiet_ms)
      return { quiet: false, ms: elapsed } if elapsed >= max_ms

      clock.sleep_ms((max_ms - elapsed).clamp(1, POLL_MS))
    end
  end

  def quiet?(tracker, now, quiet_ms)
    tracker.pending(ignore_older_ms: IGNORE_OLDER_MS).zero? && now - tracker.last_event_at >= quiet_ms
  end

  def clock
    ApplyMate::Client::Browser::Clock
  end
end
