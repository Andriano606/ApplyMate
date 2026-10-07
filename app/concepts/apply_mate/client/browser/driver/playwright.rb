require 'playwright/web_socket_client'
require 'playwright/web_socket_transport'

# The only apply driver: one Camoufox lease from browserd, driven over the Playwright protocol
# (playwright-ruby-client). Methods are thin Playwright calls; the algorithms built on them (goto, Cloudflare wait,
# settle, locate) are operations in ApplyMate::Client::Browser::Operation. Session is the public facade.
#
# Deadlines: every primitive that waits clamps its timeout to the time left before `deadline` (#clamp_ms) and raises
# DeadlineExceeded when none is left. Read-only primitives (title, content, frames, cookies, current_url,
# screenshot) are not deadline-checked so failure artifacts can still be taken; calls without a Playwright timeout
# are bounded by the lease TTL (browserd kills the browser, the ws drops, pending calls fail -> Crashed).
#
# Errors: a lost connection (ws closed, browser killed or crashed, page/context closed) raises Crashed. Any other
# Playwright::Error (navigation failure, action timeout, bad selector) propagates unchanged.
class ApplyMate::Client::Browser::Driver::Playwright
  include ApplyMate::Logging

  # Probe functions (one JS function expression per file, leading `//` comment lines and the trailing `;` that
  # prettier adds are stripped), read once at load: no IO per call.
  PROBES = Dir[File.expand_path('../probe/*.js', __dir__)].to_h do |path|
    source = File.read(path).gsub(%r{^\s*//.*\n}, '').strip.delete_suffix(';')
    [ File.basename(path, '.js').to_sym, source.freeze ]
  end.freeze

  CONNECT_TIMEOUT_S = 30
  PROBE_TIMEOUT_MS = 5_000
  ACTION_TIMEOUT_MS = 10_000
  UPLOAD_TIMEOUT_MS = 30_000
  SCREENSHOT_TIMEOUT_MS = 15_000

  CONNECTION_ERRORS = [
    ::Playwright::TargetClosedError, ::Playwright::DriverCrashedError,
    ::Playwright::WebSocketTransport::AlreadyDisconnectedError, ::Playwright::WebSocketClient::TransportError,
    Timeout::Error, EOFError, IOError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE
  ].freeze

  attr_reader :deadline, :tracker

  def initialize(lease:, deadline:)
    @lease = lease
    @deadline = deadline
  end

  # No new_context options: Camoufox owns locale, timezone and fingerprint (see .ai/docs/browser.md, Deviations).
  def start
    check_deadline!
    guard do
      @execution = Timeout.timeout(CONNECT_TIMEOUT_S) do
        ::Playwright.connect_to_browser_server(lease.ws_endpoint, browser_type: 'firefox')
      end
      @context = @execution.browser.new_context
      @page = @context.new_page
    end
    @tracker = ApplyMate::Client::Browser::NetTracker.new(@page)
    self
  end

  def close
    @tracker&.dispose
    @execution&.stop
  rescue StandardError => e
    log(event: 'browser.driver_stop_failed', level: :warn, lease_id: lease.id, error: e.class.name)
  ensure
    ApplyMate::Client::Browser::Operation::ReleaseLease.call(lease:)
  end

  def remaining_ms
    ApplyMate::Client::Browser::Clock.remaining_ms(deadline)
  end

  def navigate(url, timeout_ms:)
    timeout = clamp_ms(timeout_ms)
    guard { @page.goto(url, waitUntil: 'domcontentloaded', timeout:)&.status }
  end

  def wait_for_network_idle(timeout_ms:)
    timeout = clamp_ms(timeout_ms)
    guard { @page.wait_for_load_state(state: 'networkidle', timeout:) }
    true
  rescue ::Playwright::TimeoutError
    false
  end

  def title
    guard { @page.title }
  end

  def content(frame = main_frame)
    guard { frame.content }
  end

  def main_frame
    @page.main_frame
  end

  def frames
    @page.frames
  end

  def evaluate(frame, js, arg = nil)
    check_deadline!
    guard { frame.evaluate(js, arg:) }
  end

  def mouse_move(x, y, steps:)
    check_deadline!
    guard { @page.mouse.move(x, y, steps:) }
  end

  def mouse_wheel(delta_x, delta_y)
    check_deadline!
    guard { @page.mouse.wheel(delta_x, delta_y) }
  end

  def count(locator)
    check_deadline!
    guard { locator.count }
  end

  def click(locator)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    guard { locator.click(timeout:) }
  end

  def fill(locator, text)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    guard { locator.fill(text, timeout:) }
  end

  def press(locator, key)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    guard { locator.press(key, timeout:) }
  end

  def select(locator, value:, label:)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    guard { locator.select_option(value:, label:, timeout:) }
  end

  def set_checked(locator, value)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    guard { locator.set_checked(value, timeout:) }
  end

  def upload(locator, path, via_chooser:)
    timeout = clamp_ms(UPLOAD_TIMEOUT_MS)
    return guard { locator.set_input_files(path, timeout:) } unless via_chooser

    guard { @page.expect_file_chooser(timeout:) { locator.click(timeout:) }.set_files(path, timeout:) }
  end

  def probe(name, locator, arg = nil)
    timeout = clamp_ms(PROBE_TIMEOUT_MS)
    guard { locator.evaluate(PROBES.fetch(name), arg:, timeout:) }
  end

  def screenshot(full_page:)
    guard { @page.screenshot(fullPage: full_page, type: 'png', timeout: SCREENSHOT_TIMEOUT_MS) }
  end

  def cookies
    guard { @context.cookies.map { |cookie| "#{cookie['name']}=#{cookie['value']}" }.join('; ') }
  end

  def current_url
    @page.url
  end

  private

  attr_reader :lease

  def clamp_ms(milliseconds)
    [ milliseconds, check_deadline! ].min
  end

  def check_deadline!
    remaining = remaining_ms
    raise ApplyMate::Client::Browser::DeadlineExceeded, "scope deadline passed #{-remaining} ms ago" if remaining <= 0

    remaining
  end

  # playwright-ruby-client 1.63 rejects calls pending on a dropped connection with TargetClosedError, but a call
  # made after the drop hits `nil.value!` (Connection#async_send_message_to_server returns nil once closed). Both
  # mean the browser is gone.
  def guard
    yield
  rescue *CONNECTION_ERRORS => e
    raise ApplyMate::Client::Browser::Crashed, "browser connection lost: #{e.class}: #{e.message.to_s.truncate(200)}"
  rescue NoMethodError => e
    raise unless e.receiver.nil? && e.name == :value!

    raise ApplyMate::Client::Browser::Crashed, 'browser connection lost: connection already closed'
  end
end
