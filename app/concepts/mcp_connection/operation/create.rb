# frozen_string_literal: true

# Returns the user's personal MCP token, creating it on first use. Idempotent:
# a double click or two tabs end up with the same single token (unique partial
# index on api_tokens.user_id WHERE personal).
class McpConnection::Operation::Create < ApplyMate::Operation::Base
  def perform!(current_user:, **)
    authorize! :mcp, :connect?

    api_token = ApiToken.create_or_find_by!(user: current_user, personal: true) do |token|
      token.name = ApiToken::PERSONAL_NAME
    end
    self.model = ApplyMate::Operation::Struct.new(api_token:)
  end
end
