# frozen_string_literal: true

# Drives the Gemini web UI via Ferrum (no public API key needed) and returns the
# rendered markdown answer for a prompt. Capabilities: :browser_backed only — no
# native JSON schema (callers run in text mode: format_instructions + ResponseSchema::Json
# parsing), no images (images raise CapabilityMissing), no token usage. Slow: CALL_SECONDS
# per call (.call_seconds), which AiHandler gives a request without its own timeout.
#
# Resource bound: its Chrome runs under ApplyMate::Client::LocalChrome (at most ONE local
# Chrome per process, shared with the Grover CV render). The apply worker runs APPLY_SLOTS
# threads that may each ask while holding a browserd lease. A call waits for the slot only
# while its own Request#timeout still leaves SETUP_SECONDS, then raises LocalChrome::Busy;
# a timeout shorter than SETUP_SECONDS raises DeadlineTooShort at once (no time, not a busy
# slot). The answer wait is cut to what is left of the timeout. Nothing here waits without
# a deadline.
#
# Manual smoke test:
#   client = ApplyMate::Ai::Client::GeminiScraping.new
#   request = ApplyMate::Ai::Request.for(kind: :verify, text: "Say hello in Ukrainian",
#                                        timeout: ApplyMate::Ai::Client::GeminiScraping::CALL_SECONDS)
#   puts client.complete(request).text

class ApplyMate::Ai::Client::GeminiScraping < ApplyMate::Ai::Client::Base
  # Raised when generation never completes. Unlike Ferrum::TimeoutError (whose
  # #message is hardcoded), this preserves the diagnostic context we attach.
  class ResponseTimeoutError < StandardError; end

  # Longest answer wait (polling the web UI). Request#timeout caps it further.
  RESPONSE_TIMEOUT = 180
  # Chrome launch + gemini.google.com load + input ready on a Pi 5, before the answer wait.
  SETUP_SECONDS = 60
  # Worst case of one call once the slot is held.
  CALL_SECONDS = SETUP_SECONDS + RESPONSE_TIMEOUT

  def self.capabilities
    %i[browser_backed].freeze
  end

  def self.call_seconds(_kind)
    CALL_SECONDS
  end

  def self.validate_api_key!(api_key:)
    true
  end

  # Accepts and ignores api_key/host/model so AiHandler can build every client the same way.
  def initialize(**)
  end

  # The whole call (slot wait + Chrome + answer) ends within request.timeout seconds.
  def complete(request)
    assert_request!(request)
    prompt = [ request.system, *request.messages.map { |message| message[:content] } ].compact.join("\n\n")
    deadline = monotonic + request.timeout
    text = with_slot(deadline) { scrape_answer(prompt, deadline) }
    ApplyMate::Ai::Response.new(text:, usage: ApplyMate::Ai::Usage::UNKNOWN)
  end

  def list_models
    [ 'gemini-web-scraping' ]
  end

  INPUT_SELECTOR = 'div.ql-editor[contenteditable="true"]'
  RESPONSE_SELECTOR = '.markdown.markdown-main-panel.enable-updated-hr-color'
  # Send button returns to its disabled "idle" state only after generation ends
  # (during generation it is replaced by a stop button).
  IDLE_SEND_SELECTOR = '.disabled button.send-button.submit'

  private

  # The slot wait is what the timeout leaves beyond SETUP_SECONDS. No such time at all is the caller's deadline, not
  # a busy slot: DeadlineTooShort before the slot is touched.
  def with_slot(deadline, &)
    wait = deadline - monotonic - SETUP_SECONDS
    if wait.negative?
      raise ApplyMate::Ai::Client::Base::DeadlineTooShort,
            "#{self.class.name}: #{(deadline - monotonic).round} s left, a call needs more than #{SETUP_SECONDS} s"
    end

    ApplyMate::Client::LocalChrome.hold(wait:, &)
  end

  def scrape_answer(text, deadline)
    browser = launch_browser
    context = browser.contexts.create
    page = context.create_page
    navigate_to(page, 'https://gemini.google.com/app')
    wait_for_selector(page, INPUT_SELECTOR, timeout: 20)
    input_field = page.at_css(INPUT_SELECTOR)
    page.execute('arguments[0].innerText = arguments[1]', input_field, text)
    input_field.type(:Enter)

    result = wait_for_response(page, timeout: [ RESPONSE_TIMEOUT, deadline - monotonic ].min)
    if result.blank?
      raise '[ApplyMate::Ai::Client::GeminiScraping] No results found'
    end
    result
  rescue StandardError => e
    Rails.logger.error "[ApplyMate::Ai::Client::GeminiScraping] Error: #{e.message}"
    raise e
  ensure
    page&.close
    context&.dispose
    browser&.quit
  end

  # Launched per call (and quit in scrape_answer's ensure), not in the constructor, so
  # building the client or rejecting a request never starts Chrome.
  def launch_browser
    # A local Chrome inside the worker container (there is no shared Chrome container;
    # apply-time browsing goes through browserd, see .ai/docs/browser.md).
    Ferrum::Browser.new(
      window_size: [ 1920, 1080 ],
      timeout: 30,
      browser_options: {
        # Chrome's sandbox needs unprivileged user namespaces, which the
        # staging host (Raspberry Pi) blocks via AppArmor. Without these flags
        # Chrome dies on boot with "No usable sandbox!" and never exposes its
        # CDP websocket, surfacing as Ferrum::ProcessTimeoutError. Required when
        # launching a local browser inside the container; harmless when set.
        'no-sandbox': nil,
        # /dev/shm is only 64M inside the container — keep Chrome off it.
        'disable-dev-shm-usage': nil
      }
    )
  end

  def wait_for_selector(page, selector, timeout: 5)
    deadline = monotonic + timeout
    loop do
      return true if page.at_css(selector)

      if monotonic > deadline
        raise ResponseTimeoutError, "Selector #{selector.inspect} not found within #{timeout}s"
      end

      sleep 0.2
    end
  end

  # Number of consecutive unchanged polls (~0.3s each) that mark the answer as
  # complete when the idle-send signal never matches (UI/selector drift fallback).
  STABLE_POLLS_FALLBACK = 12

  # Waits until Gemini has finished generating, then returns the answer text.
  #
  # We deliberately do NOT wait for the transient `.thinking` spinner to appear:
  # on a fast response it shows and disappears within a single poll cycle, so it
  # was frequently missed, leaving the old code blocked for the full timeout even
  # though the answer was already on screen. Instead we treat the response as
  # complete when the answer text has stopped changing between polls, confirmed
  # either by the send button returning to idle (fast path) or by the text
  # staying stable for ~3.5s (fallback if the idle selector ever drifts).
  def wait_for_response(page, timeout: 180)
    deadline = monotonic + timeout
    last_text = nil
    stable_polls = 0
    last_gesture = 0

    loop do
      # Keep the session looking human, but throttled so the gestures never
      # dominate the poll interval (that throttling bug is what hid `.thinking`).
      if monotonic - last_gesture > 3
        safe_cdp { human_scroll(page); human_wheel(page) }
        last_gesture = monotonic
      end

      idle = safe_cdp { page.at_css(IDLE_SEND_SELECTOR) }
      text = safe_cdp { page.css(RESPONSE_SELECTOR).last&.inner_text }.to_s.strip

      stable_polls = text.present? && text == last_text ? stable_polls + 1 : 0
      last_text = text

      if text.present? && ((idle && stable_polls >= 1) || stable_polls >= STABLE_POLLS_FALLBACK)
        return text
      end

      if monotonic > deadline
        raise ResponseTimeoutError,
          "Gemini response did not complete within #{timeout}s (idle=#{!idle.nil?}, length=#{text.length})"
      end

      sleep 0.3
    end
  end

  # Runs a CDP interaction, swallowing a single transient command timeout so one
  # slow round-trip doesn't abort the whole response wait.
  def safe_cdp
    yield
  rescue Ferrum::Error => e
    Rails.logger.debug { "[ApplyMate::Ai::Client::GeminiScraping] transient CDP error: #{e.class}" }
    nil
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def human_wheel(page)
    x = rand(400..1200)
    y = rand(300..800)
    delta = rand(100..400)

    page.command(
      'Input.dispatchMouseEvent',
      type: 'mouseWheel',
      x: x,
      y: y,
      deltaX: 0,
      deltaY: delta,
      pointerType: 'mouse'
    )

    sleep(rand(0.1..0.4))
  end

  def human_scroll(page)
    anchor = page.at_css('.user-query-bubble-with-background')
    if anchor
      box = page.evaluate('document.querySelector(".user-query-bubble-with-background").getBoundingClientRect().toJSON()')
      cx = box['x'] + box['width'] / 2
      cy = box['y'] + box['height'] / 2
    else
      cx, cy = 960, 540
    end
    page.mouse.move(x: cx, y: cy)
    8.times do |i|
      page.mouse.scroll_to(cx, cy + i * rand(80..150))
      sleep rand(0.03..0.08)
    end
    8.times do |i|
      page.mouse.scroll_to(cx, cy + (7 - i) * rand(80..150))
      sleep rand(0.03..0.08)
    end
  end

  def navigate_to(page, url)
    page.goto(url)
  rescue Ferrum::PendingConnectionsError
    # ignore pending third-party requests (trackers, analytics)
  ensure
    begin
      page.network.wait_for_idle(timeout: 10)
    rescue Ferrum::TimeoutError, Ferrum::PendingConnectionsError
      # ignore pending third-party requests (trackers, analytics)
    end
  end
end
