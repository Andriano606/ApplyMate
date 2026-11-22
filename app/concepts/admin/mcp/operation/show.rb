# frozen_string_literal: true

# Admin page about the MCP server: the endpoint, its tools and a ready-to-paste
# `claude mcp add` command per API token of the current user (the MCP server acts
# as the token's owner, so an admin connects with their own token).
class Admin::Mcp::Operation::Show < ApplyMate::Operation::Base
  def perform!(current_user:, **)
    authorize! :mcp, :show?

    self.model = ApplyMate::Operation::Struct.new(
      api_tokens: current_user.api_tokens.order(created_at: :desc).to_a,
      tools: ::Mcp::Operation::Handle::TOOLS
    )
  end
end
