class McpPolicy < ApplicationPolicy
  def access?
    user.present?
  end

  # Any signed-in user may get (and regenerate) their own MCP token.
  def connect?
    user.present?
  end

  def show?
    user&.admin?
  end
end
