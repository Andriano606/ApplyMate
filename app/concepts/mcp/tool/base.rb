# frozen_string_literal: true

# Base for ApplyMate's MCP tools. A tool is an adapter like a controller action:
# it declares its schema, runs exactly one operation as the API-token user and
# serializes the result. Business logic belongs in the operation.
class Mcp::Tool::Base < MCP::Tool
  # Read-only tools over our own database — nothing outside ApplyMate is touched.
  READ_ONLY = { read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false }.freeze

  class << self
    private

    # Runs the operation as the token's user. Yields the successful result for
    # serialization; a failed one becomes an MCP tool error carrying its message.
    def run(operation, server_context, params = {})
      result = operation.call(params:, current_user: server_context[:current_user])
      raise Pundit::NotAuthorizedError, "Authorization was not performed in #{operation}" unless result[:pundit]
      return failure(result.error_message) if result.failure?

      success(yield(result.model))
    end

    def success(payload)
      data = payload.as_json
      MCP::Tool::Response.new([ { type: 'text', text: data.to_json } ], structured_content: data)
    end

    def failure(message)
      MCP::Tool::Response.new([ { type: 'text', text: message } ], error: true)
    end

    # total_entries is the real match count; total_pages / next_page stop at the
    # deepest page Elasticsearch can serve, so following next_page always ends.
    def pagination(collection)
      total_pages = [ collection.total_pages, Vacancy::Operation::Search.last_reachable_page(collection.per_page) ].min
      {
        page: collection.current_page,
        per_page: collection.per_page,
        total_pages:,
        total_entries: collection.total_entries,
        next_page: (collection.current_page + 1 if collection.current_page < total_pages)
      }
    end
  end
end
