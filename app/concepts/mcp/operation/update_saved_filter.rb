# frozen_string_literal: true

# MCP `update_saved_filter`: renames and/or changes one of the token user's presets. Omitted
# fields keep their values (see SavedFilterInput#filter_state). Wraps
# SavedFilter::Operation::Update, which always rewrites the whole state, so the merged state is
# passed in full.
class Mcp::Operation::UpdateSavedFilter < ApplyMate::Operation::Base
  include Mcp::Operation::SavedFilterInput

  def perform!(params:, current_user:, **)
    filter = find_saved_filter(params[:id], current_user)
    authorize! filter, :update?

    state = filter_state(params, filter)
    name  = params.key?(:name) ? params[:name] : filter.name
    self.model = run_web_operation(SavedFilter::Operation::Update,
                                   { id: filter.id, saved_filter: state.merge(name:) }, current_user)
  end
end
