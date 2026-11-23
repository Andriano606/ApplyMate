# frozen_string_literal: true

# The "Connect Claude (MCP)" modal. Opening it never creates a token — the copy
# button does (Create), so the modal stays a side-effect-free GET.
class McpConnection::Operation::Show < ApplyMate::Operation::Base
  def perform!(current_user:, **)
    authorize! :mcp, :connect?

    self.model = ApplyMate::Operation::Struct.new(api_token: current_user.personal_api_token)
  end
end
