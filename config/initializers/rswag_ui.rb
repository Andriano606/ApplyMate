# frozen_string_literal: true

Rswag::Ui.configure do |c|
  # Engines are mounted under the /admin namespace (see config/routes.rb).
  c.openapi_endpoint '/admin/api-docs/v1/swagger.yaml', 'ApplyMate API V1'

  # Options below are passed straight to SwaggerUIBundle.
  # Disable the public validator (validator.swagger.io can't reach a private host,
  # which produces the "Can't read from file ..." badge).
  c.config_object[:validatorUrl] = nil
  # Show the editable "Try it out" form by default instead of just the example value.
  c.config_object[:tryItOutEnabled] = true
end
