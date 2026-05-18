# frozen_string_literal: true

Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new

  config.lograge.custom_options = lambda do |event|
    options = { time: Time.current.iso8601(3) }
    options[:request_id] = event.payload[:request_id] if event.payload[:request_id]
    options[:user_id]    = event.payload[:user_id]    if event.payload[:user_id]
    options[:error]      = event.payload[:exception_object]&.message
    options.compact
  end
end
