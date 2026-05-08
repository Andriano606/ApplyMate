# frozen_string_literal: true

require 'webmock/rspec'

# Allow localhost connections (Capybara, ActionCable test server).
WebMock.disable_net_connect!(allow_localhost: true)
