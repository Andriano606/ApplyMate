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
    resolved_url, ats = follow_embedded_form(browser, resolved_url, ats)

    apply.update!(external_url:, resolved_url:, ats:)
  end

  # An employer page that embeds its ATS form in an iframe has no fields of its
  # own — the parent document cannot see into a cross-origin frame. Follow the
  # embed to a standalone form page so every later step works on a normal
  # top-level document.
  def follow_embedded_form(browser, resolved_url, ats)
    # Wait before concluding the page has no fields — an SPA that simply has not
    # painted yet must not be mistaken for an embed-only page.
    return [ resolved_url, ats ] if browser.wait_for_fields(timeout: 8)

    embedded = Apply::EmbeddedForm.locate(browser.iframe_sources)
    return [ resolved_url, ats ] if embedded.blank?

    Rails.logger.info("Resolve: following embedded form #{embedded}")
    browser.navigate_to(embedded)
    browser.wait_for_fields

    followed_url = browser.current_url.presence || embedded
    [ followed_url, Apply::AtsDetector.call(url: followed_url, html: browser.body) || ats ]
  end
end
