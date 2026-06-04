# frozen_string_literal: true

Rswag::Api.configure do |c|
  # Location of the generated OpenAPI files served by Rswag::Api::Engine.
  c.openapi_root = Rails.root.join('swagger').to_s
end
