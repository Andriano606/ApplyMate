# frozen_string_literal: true

# Model Context Protocol endpoint (Streamable HTTP, stateless, JSON responses).
# Authenticated with an API token: `Authorization: Bearer <token>`.
# See .ai/docs/mcp.md.
class McpController < ActionController::API
  include UserHandling

  rescue_from Pundit::NotAuthorizedError do
    response.headers['WWW-Authenticate'] = 'Bearer realm="ApplyMate MCP"'
    render json: { error: 'unauthorized' }, status: :unauthorized
  end

  def handle
    status, headers, body = Mcp::Operation::Handle.call(request:, current_user: user_from_token).model

    headers.each { |name, value| response.headers[name] = value }
    self.status = status
    self.response_body = body
  end
end
