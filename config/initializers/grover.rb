# frozen_string_literal: true

Grover.configure do |config|
  config.options = {
    launch_args: [ '--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage' ]
  }
end
