# frozen_string_literal: true

# An action (click, fill, press, type, set_checked, select) timed out on an element that Locate had already found:
# Playwright's actionability check kept failing because another element intercepts pointer events (a late cookie
# banner, a modal overlay) or the element never became visible / enabled / stable / editable. Raised by
# Driver::Playwright in place of the Playwright::TimeoutError so callers can run their gates and retry once (design
# §7.3). `locator` is the Playwright locator description (selector chain only, never a typed value), `reason` the
# matched actionability failure.
class ApplyMate::Client::Browser::Obstructed < StandardError
  attr_reader :locator, :reason

  def initialize(locator, reason)
    @locator = locator.to_s.truncate(300)
    @reason = reason
    super("#{reason}: #{@locator}")
  end
end
