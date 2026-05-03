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

    # Wait for the input field to be available
    # Using exact class match as requested
    input_selector = 'div.ql-editor[contenteditable="true"]'
    wait_for_selector(page, input_selector, timeout: 20)

    # Typing the text immediately
    input_field = page.at_css(input_selector)
    page.execute('arguments[0].innerText = arguments[1]', input_field, text)
    input_field.type(:Enter)

    # Wait for the button to change state.
    # From "stop" to "disabled".

    # Selector for exact class match:
    # stop_selector: selector showing during processing by chat
    # stop_selector = '.bard-avatar.thinking'
    # finished_selector: appear when finished
    finished_selector = '.disabled button.send-button.submit'

    # Then wait for it to finish (finished/disabled class appears)
    wait_for_selector(page, finished_selector, timeout: 120)

    # Extract content from the last markdown panel
    # class="markdown markdown-main-panel enable-updated-hr-color"
    content_selector = '.markdown.markdown-main-panel.enable-updated-hr-color'

    # Extract the last element from the array as requested
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
      return true if page.at_css(selector)

      raise Ferrum::TimeoutError if Time.now - start_time > timeout

      sleep 0.2
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
