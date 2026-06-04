# frozen_string_literal: true

require 'rails_helper'

RSpec.configure do |config|
  # Where rswag:specs:swaggerize writes the generated OpenAPI documents.
  config.openapi_root = Rails.root.join('swagger').to_s

  config.openapi_specs = {
    'v1/swagger.yaml' => {
      openapi: '3.0.1',
      info: {
        title: 'ApplyMate API',
        version: 'v1'
      },
      paths: {},
      # Relative server so "Try it out" / Execute targets whatever host serves the
      # UI (localhost in dev, dev.applymate.io when deployed) — not a hardcoded host.
      servers: [
        { url: '/' }
      ],
      components: {
        securitySchemes: {
          bearerAuth: {
            type: :http,
            scheme: :bearer
          }
        }
      }
    }
  }

  config.openapi_format = :yaml
end
