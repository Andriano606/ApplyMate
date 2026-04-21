# frozen_string_literal: true

require_relative 'production'

Rails.application.configure do
  config.action_controller.default_url_options = { host: ENV.fetch('APP_HOST', 'localhost'), protocol: 'https' }
  config.action_mailer.default_url_options = { host: ENV.fetch('APP_HOST', 'localhost'), protocol: 'https' }
  config.hosts << ENV.fetch('APP_HOST', 'localhost')
  config.host_authorization = { exclude: ->(request) { request.path == '/up' } }

  config.active_storage.service = :minio_staging

  # Proxy file downloads through Rails instead of redirecting to MinIO directly.
  # Required for ngrok access — browser cannot reach 192.168.31.58 from outside the LAN.
  config.active_storage.resolve_model_to_route = :rails_storage_proxy
end
