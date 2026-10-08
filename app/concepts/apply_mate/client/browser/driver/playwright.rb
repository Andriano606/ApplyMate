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
# Errors: a lost connection (ws closed, browser killed or crashed, page/context closed) raises Crashed. An action
# (click, fill, press, type, set_checked, select) whose actionability wait times out because another element
# intercepts pointer events or the element is not visible / enabled / stable / editable raises Obstructed. Any other
# Playwright::Error (navigation failure, other timeouts, bad selector) propagates unchanged.
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
  # Frames evaluated by #evaluate_all_frames and masked by #mask_locators, main frame first (Playwright lists frames
  # in attach order, so a parent always precedes its children). Bounds the protocol calls of one snapshot on
  # ad-heavy pages; the application iframe is attached early, long before lazy ad slots.
  MAX_FRAMES = 20
  # Everything a person can type into or choose in: masked in screenshots so artifacts never show filled values.
  MASK_SELECTOR = 'input:visible, textarea, select, [contenteditable], [role=combobox], [role=textbox]'.freeze
  OBSTRUCTION = /intercepts pointer events|element is not (?:visible|enabled|stable|editable)/
  # #set_checked on a control that has no box (display: none): one in-page click when the state differs.
  TOGGLE_HIDDEN_JS = '(el, value) => { if (!el.disabled && el.checked !== value) el.click(); return el.checked; }'

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

  # `js` (a function of `arg`) in each of the first MAX_FRAMES frames:
  # [{ index:, url:, name:, parent_index:, element_id:, value: }]. element_id = id attribute of the <iframe> element
  # that holds the frame (read from the parent side, so it works for cross-origin frames); value nil when that frame
  # cannot be evaluated (detached mid-call, navigating).
  def evaluate_all_frames(js, arg = nil)
    check_deadline!
    all = frames.first(MAX_FRAMES)
    all.each_with_index.map do |frame, index|
      parent = frame.parent_frame
      { index:, url: frame.url, name: frame.name, parent_index: parent && all.index(parent),
        element_id: parent && frame_element_id(frame), value: evaluate_in(frame, js, arg) }
    end
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

  # trial: Playwright's actionability checks (visible, stable, enabled, receives the pointer event) without the click.
  def click(locator, trial: false)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    act(locator) { locator.click(timeout:, trial:) }
  end

  def fill(locator, text)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    act(locator) { locator.fill(text, timeout:) }
  end

  # Key by key with `delay_ms` between keystrokes (trusted keyboard events, for inputs that ignore #fill). The
  # timeout grows with the text so a long answer is not cut off by the actionability timeout.
  def type(locator, text, delay_ms:)
    timeout = clamp_ms(ACTION_TIMEOUT_MS + (text.to_s.length * delay_ms))
    act(locator) { locator.press_sequentially(text.to_s, delay: delay_ms, timeout:) }
  end

  def press(locator, key)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    act(locator) { locator.press(key, timeout:) }
  end

  def select(locator, value:, label:)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    act(locator) { locator.select_option(value:, label:, timeout:) }
  end

  # A visible control gets Playwright's trusted check. A control nobody can see (display: none under a styled toggle
  # that is not its <label>) has no box to click, so Playwright would wait for visibility until the timeout: it is
  # toggled in the page instead (HTMLElement#click fires the click / input / change events a person's click would),
  # only when its state differs.
  def set_checked(locator, value)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    return act(locator) { locator.set_checked(value, timeout:) } if guard { locator.visible? }

    guard { locator.evaluate(TOGGLE_HIDDEN_JS, arg: value, timeout:) }
  end

  def scroll_into_view(locator)
    timeout = clamp_ms(ACTION_TIMEOUT_MS)
    guard { locator.scroll_into_view_if_needed(timeout:) }
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

  # `mask`: locators painted over (Playwright resolves them in every frame they belong to).
  def screenshot(full_page:, mask: [])
    guard do
      @page.screenshot(fullPage: full_page, type: 'png', timeout: SCREENSHOT_TIMEOUT_MS, mask: mask.presence)
    end
  end

  # MASK_SELECTOR in the main frame and every child frame (up to MAX_FRAMES).
  def mask_locators
    frames.first(MAX_FRAMES).map { |frame| frame.locator(MASK_SELECTOR) }
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

  def act(locator)
    guard { yield }
  rescue ::Playwright::TimeoutError => e
    reason = e.message.to_s[OBSTRUCTION]
    raise unless reason

    raise ApplyMate::Client::Browser::Obstructed.new(locator, reason)
  end

  def evaluate_in(frame, js, arg)
    guard { frame.evaluate(js, arg:) }
  rescue ::Playwright::Error
    nil
  end

  def frame_element_id(frame)
    handle = guard { frame.frame_element }
    guard { handle.get_attribute('id') }.presence
  rescue ::Playwright::Error
    nil
  ensure
    dispose(handle)
  end

  def dispose(handle)
    handle&.dispose
  rescue ::Playwright::Error
    nil # the frame may be gone already; the handle dies with it
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
