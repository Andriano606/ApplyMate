# frozen_string_literal: true

# browserd's playwright-core differs from Playwright::COMPATIBLE_PLAYWRIGHT_VERSION of the pinned
# playwright-ruby-client gem. Permanent until the image and the Gemfile pin are bumped together.
class ApplyMate::Client::Browser::VersionMismatch < StandardError
end
