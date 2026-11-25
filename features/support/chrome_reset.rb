# frozen_string_literal: true

require 'capybara/selenium/driver'

# Chrome 158+ rejects the CDP call Capybara 3.40 (the latest release) makes in
# Capybara::Selenium::Driver::ChromeDriver#reset! after every scenario —
#   Storage.clearDataForOrigin(origin: '*')  →  "invalid argument: * is not a valid URL"
# — so every scenario failed in its teardown on CI's chrome-stable. Clear the same data
# without the wildcard: cookies browser-wide, storage for the app server's origin (the only
# origin the scenarios open). Drop this file once Capybara stops sending origin '*'.
module ChromeResetWithoutWildcardOrigin
  def execute_cdp(cmd, params = {})
    return super unless cmd == 'Storage.clearDataForOrigin' && params[:origin] == '*'

    super('Network.clearBrowserCookies')
    origin = Capybara.current_session.server&.base_url
    super(cmd, params.merge(origin:)) if origin
  end
end

Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeResetWithoutWildcardOrigin)
