# frozen_string_literal: true

require 'rspec/mocks'

# Make allow/allow_any_instance_of available in Cucumber Before/After hooks
World(RSpec::Mocks::ExampleMethods)

Capybara.default_max_wait_time = 30

Before do
  ActiveJob::Base.queue_adapter.immediate = true
  RSpec::Mocks.setup
end

After do
  RSpec::Mocks.verify
  RSpec::Mocks.teardown
end
