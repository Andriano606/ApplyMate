# frozen_string_literal: true

# :browser examples drive the real ApplyMate::Client::Browser::Driver::Playwright against a browserd (Camoufox)
# and FixtureSite. They run whenever BROWSERD_URL is set (dev: `docker compose up -d browserd`, Conductor writes it
# to .env.test.local; CI: the `browser_specs` job) and are excluded otherwise, so the production driver is tested
# wherever a browserd is available. Only this file reads BROWSERD_URL for that decision; nothing in app/ changes
# behaviour for specs.
RSpec.configure do |config|
  config.filter_run_excluding(browser: true) if ENV['BROWSERD_URL'].blank?

  config.before(:suite) do
    FixtureSite.start if RSpec.world.filtered_examples.values.flatten.any? { |example| example.metadata[:browser] }
  end

  config.after(:suite) { FixtureSite.stop }

  # The one PublicAddressGuard seam: the fixture host is a private address (the docker host), so in :browser
  # examples URLs on it resolve to a Resolution; every other URL runs the real ResolvePublicAddress.
  config.before(:each, browser: true) do
    FixtureSite.reset!
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call).and_wrap_original do |original, **args|
      URI.parse(args.fetch(:url).to_s).host == FixtureSite.host ? FixtureSite.resolution(args[:url]) : original.call(**args)
    end
  end
end
