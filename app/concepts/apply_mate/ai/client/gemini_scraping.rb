# frozen_string_literal: true

# Drives the Gemini web UI via Ferrum (no public API key needed).
# Connects to the persistent, logged-in Chrome container (see CHROME_HOST/PORT)
# and returns the rendered markdown answer for a prompt.
#
# Manual smoke test:
#   client = ApplyMate::Ai::Client::GeminiScraping.new
#   puts client.ask("Say hello in Ukrainian")

class ApplyMate::Ai::Client::GeminiScraping < ApplyMate::Ai::Client::Base
  # Raised when generation never completes. Unlike Ferrum::TimeoutError (whose
  # #message is hardcoded), this preserves the diagnostic context we attach.
  class ResponseTimeoutError < StandardError; end

  CHROME_HOST = ENV.fetch('CHROME_HOST', 'chrome-vnc')
  CHROME_PORT = ENV.fetch('CHROME_PORT', 9222)

  def initialize(**)
    # Connect to the persistent, already-logged-in Chrome container instead of
    # launching a fresh local Chrome per request. Spawning a cold browser on
    # every `ask` intermittently exceeds Ferrum's startup/command timeout on
    # constrained hosts (prod runs on a Raspberry Pi), which surfaces as the
    # random "Timed out waiting for response" error.
    @browser = Ferrum::Browser.new(
      # url: "http://#{CHROME_HOST}:#{CHROME_PORT}",
      window_size: [ 1920, 1080 ],
      timeout: 30
    )
  end

  INPUT_SELECTOR = 'div.ql-editor[contenteditable="true"]'
  RESPONSE_SELECTOR = '.markdown.markdown-main-panel.enable-updated-hr-color'
  # Send button returns to its disabled "idle" state only after generation ends
  # (during generation it is replaced by a stop button).
  IDLE_SEND_SELECTOR = '.disabled button.send-button.submit'

  def ask(text)
    context = @browser.contexts.create
    page = context.create_page
    navigate_to(page, 'https://gemini.google.com/app')
    wait_for_selector(page, INPUT_SELECTOR, timeout: 20)
    input_field = page.at_css(INPUT_SELECTOR)
    page.execute('arguments[0].innerText = arguments[1]', input_field, text)
    input_field.type(:Enter)

    result = wait_for_response(page, timeout: 180)
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
    @browser&.quit
  end

  def self.validate_api_key!(api_key:)
    true
  end

  def list_models
    [ 'gemini-web-scraping' ]
  end

  private

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
