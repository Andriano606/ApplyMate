# frozen_string_literal: true

# c = ApplyMate::Client::Browser.new
# r = c.fetch_body('https://djinni.co/jobs/')

class ApplyMate::Client::Browser < ApplyMate::Client::Base
  CHROME_HOST = ENV.fetch('CHROME_HOST', 'chrome-vnc')
  CHROME_PORT = ENV.fetch('CHROME_PORT', 9222)

  def initialize
    @browser = Ferrum::Browser.new(
      url: "http://#{CHROME_HOST}:#{CHROME_PORT}",
      window_size: [ 1920, 1080 ],
      browser_options: { 'no-sandbox': nil }
    )
  end

  def fetch_body(url)
    @page = @browser.create_page
    navigate_to(url)

    return if @page.current_url != url

    @page.body
  rescue StandardError => e
    Rails.logger.error "ApplyMate::Client::Browser Error: #{e.message}"
    raise e
  ensure
    @page&.close
  end

  private

  def navigate_to(url)
    @page.goto(url)
  rescue Ferrum::PendingConnectionsError
    # ignore pending third-party requests (trackers, analytics)
  ensure
    begin
      @page.network.wait_for_idle(timeout: 10)
    rescue Ferrum::TimeoutError, Ferrum::PendingConnectionsError
      # ignore pending third-party requests (trackers, analytics)
    end
  end
end
