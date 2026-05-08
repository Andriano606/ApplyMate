# frozen_string_literal: true

require 'rspec/mocks'

# Make allow/allow_any_instance_of available in Cucumber Before/After hooks
World(RSpec::Mocks::ExampleMethods)

Capybara.default_max_wait_time = 30

Before do
  if ActiveJob::Base.queue_adapter.is_a?(ActiveJob::QueueAdapters::TestAdapter)
    ActiveJob::Base.queue_adapter.perform_enqueued_jobs = true
    ActiveJob::Base.queue_adapter.perform_enqueued_at_jobs = true
  end
  RSpec::Mocks.setup
end

After do
  RSpec::Mocks.verify
  RSpec::Mocks.teardown
end
