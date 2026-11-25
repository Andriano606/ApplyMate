# frozen_string_literal: true

# MCP `delete_saved_filter`: removes one of the token user's presets. Wraps
# SavedFilter::Operation::Destroy (if it was the web search's default, the FK nullifies it).
class Mcp::Operation::DeleteSavedFilter < ApplyMate::Operation::Base
  include Mcp::Operation::SavedFilterInput

  def perform!(params:, current_user:, **)
    filter = find_saved_filter(params[:id], current_user)
    authorize! filter, :destroy?

    self.model = run_web_operation(SavedFilter::Operation::Destroy, { id: filter.id }, current_user)
  end
end
