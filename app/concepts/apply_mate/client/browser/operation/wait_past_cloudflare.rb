# Port of the attached runtime's waitPastCloudflare. While the page is a Cloudflare interstitial, keep the mouse
# moving (~every second, a wheel scroll every 3rd poll): the managed challenge passes on signs of a live user.
# model = [passed, was_challenge].
#
# Stop conditions (as the JS): never challenged -> return after 2 polls; challenged and then cleared -> return once
# the body has more than 80 visible characters or 2 s have passed since the start; still challenged at the budget
# -> [false, true]. Termination: every poll sleeps 300..1400 ms and the loop ends at min(max_ms, time left).
#
# The challenge predicate is ApplyMate::Client::Response.cloudflare_interstitial? on the title and the HTML
# (see that method for why 'challenge-platform' alone does not count in a rendered page).
class ApplyMate::Client::Browser::Operation::WaitPastCloudflare < ApplyMate::Operation::Base
  NEVER_CHALLENGED_POLLS = 2
  CLEARED_TEXT_CHARS = 80
  CLEARED_GRACE_MS = 2_000
  BODY_TEXT_JS = "() => (document.body ? document.body.innerText.slice(0, 600) : '')".freeze

  def perform!(driver:, max_ms:, **)
    skip_authorize
    self.model = wait(driver, [ max_ms, driver.remaining_ms ].min)
  end

  private

  def wait(driver, budget_ms)
    started_at = clock.now_ms
    was_challenge = false
    polls = 0
    while clock.now_ms - started_at < budget_ms
      polls += 1
      if challenge?(driver)
        was_challenge = true
        move_like_a_user(driver, polls)
        clock.sleep_ms(rand(900..1400))
      elsif !was_challenge
        return [ true, false ] if polls >= NEVER_CHALLENGED_POLLS

        clock.sleep_ms(300)
      else
        return [ true, true ] if cleared?(driver, started_at)

        clock.sleep_ms(500)
      end
    end
    [ false, was_challenge ]
  end

  def challenge?(driver)
    ApplyMate::Client::Response.cloudflare_interstitial?(read { driver.title }) ||
      ApplyMate::Client::Response.cloudflare_interstitial?(read { driver.content })
  end

  def cleared?(driver, started_at)
    text = read { driver.evaluate(driver.main_frame, BODY_TEXT_JS) }
    text.gsub(/\s+/, '').length > CLEARED_TEXT_CHARS || clock.now_ms - started_at > CLEARED_GRACE_MS
  end

  def move_like_a_user(driver, polls)
    driver.mouse_move(rand(80..1000), rand(80..650), steps: rand(6..16))
    driver.mouse_wheel(0, rand(-60..160)) if (polls % 3).zero?
  rescue ::Playwright::Error
    nil # the challenge may be navigating away under the pointer
  end

  # The page may be mid-navigation (the challenge reloading into the real page): a failed read is an empty read.
  def read
    yield.to_s
  rescue ::Playwright::Error
    ''
  end

  def clock
    ApplyMate::Client::Browser::Clock
  end
end
