# frozen_string_literal: true

# First external step: opens the shared browser session (handler owns it),
# follows every redirect from the stored external URL — including JS redirects,
# which is why this happens in a browser and not over HTTP — and records the
# final URL plus the detected ATS. Downstream steps pick the adapter (ATS API)
# or the browser path based on what was detected here.
class Apply::Operation::External::Resolve < Apply::Operation::Base
  def start_status
    :fetching_form
  end

  def error_status
    :failed_fetching_form
  end

  private

  def run!(apply:, handler:, **)
    external_url = apply.vacancy.external_url
    raise 'No external apply URL stored for this vacancy' if external_url.blank?

    browser = ApplyMate::Client::Browser.new
    handler.browser = browser

    browser.navigate_to(external_url)

    resolved_url = browser.current_url.presence || external_url
    ats          = Apply::AtsDetector.call(url: resolved_url, html: browser.body)

    apply.update!(external_url:, resolved_url:, ats:)
  end
end
