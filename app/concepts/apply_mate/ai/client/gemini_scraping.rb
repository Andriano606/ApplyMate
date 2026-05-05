# frozen_string_literal: true

class ApplyMate::Ai::Client::GeminiScraping < ApplyMate::Ai::Client::Base
  def initialize(**)
    @browser = Ferrum::Browser.new(
      window_size: [ 1920, 1080 ],
      browser_options: { 'no-sandbox': nil }
    )
  end

  def ask(text)
    context = @browser.contexts.create
    page = context.create_page
    navigate_to(page, 'https://gemini.google.com/app')
    input_selector = 'div.ql-editor[contenteditable="true"]'
    wait_for_selector(page, input_selector, timeout: 20)
    input_field = page.at_css(input_selector)
    page.execute('arguments[0].innerText = arguments[1]', input_field, text)
    input_field.type(:Enter)
    finished_selector1 = '.thinking'
    wait_for_selector(page, finished_selector1, timeout: 120)
    finished_selector2 = '.disabled button.send-button.submit'
    wait_for_selector(page, finished_selector2, timeout: 120)
    human_scroll(page)
    sleep(1)
    human_scroll(page)
    content_selector = '.markdown.markdown-main-panel.enable-updated-hr-color'
    elements = page.css(content_selector)
    if elements.any?
      elements.last.inner_text.strip
    else
      ''
    end
  rescue StandardError => e
    Rails.logger.error "[ApplyMate::Ai::Client::GeminiScraping] Error: #{e.message}"
    raise e
  ensure
    page&.close
    context&.dispose
  end

  def self.validate_api_key!(api_key:)
    true
  end

  def list_models
    [ 'gemini-web-scraping' ]
  end

  private

  def wait_for_selector(page, selector, timeout: 5)
    start_time = Time.now
    loop do
      human_scroll(page)

      return true if page.at_css(selector)

      raise Ferrum::TimeoutError if Time.now - start_time > timeout

      sleep 0.2
    end
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
