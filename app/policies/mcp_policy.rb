# frozen_string_literal: true

# The MCP endpoint (POST /mcp) is for API-token holders only; what each tool may
# do is then decided by the policies of the operations it calls.
class McpPolicy < ApplicationPolicy
  def access?
    user.present?
  end
end
