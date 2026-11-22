# frozen_string_literal: true

# MCP `list_saved_filters`: the user's search presets (the pills above the web search bar).
class Mcp::Operation::ListSavedFilters < ApplyMate::Operation::Base
  def perform!(current_user:, **)
    authorize! SavedFilter.new(user: current_user), :index?

    self.model = current_user.saved_filters.order(:name).to_a
  end
end
