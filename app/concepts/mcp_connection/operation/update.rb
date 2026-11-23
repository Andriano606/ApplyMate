# frozen_string_literal: true

# Regenerates the user's personal MCP token (creating it first if there is none):
# the old value stops working at once, so every client connected with it has to
# be re-added with the new command.
class McpConnection::Operation::Update < ApplyMate::Operation::Base
  def perform!(current_user:, **)
    authorize! :mcp, :connect?

    api_token = run_operation(McpConnection::Operation::Create, { current_user: }).model.api_token
    api_token.update!(token: ApiToken.generate_unique_secure_token, last_used_at: nil)

    self.model = ApplyMate::Operation::Struct.new(api_token:)
    notice(I18n.t('mcp_connection.update.success'))
  end
end
