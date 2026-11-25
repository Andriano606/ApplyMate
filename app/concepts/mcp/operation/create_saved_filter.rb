# frozen_string_literal: true

# MCP `create_saved_filter`: saves a new search preset for the token user. Wraps
# SavedFilter::Operation::Create — the web "save filter" form — so both share the rules
# (unique name per user; the new preset becomes the one the web search opens with).
class Mcp::Operation::CreateSavedFilter < ApplyMate::Operation::Base
  include Mcp::Operation::SavedFilterInput

  def perform!(params:, current_user:, **)
    authorize! SavedFilter.new(user: current_user), :create?

    state = filter_state(params)
    self.model = run_web_operation(SavedFilter::Operation::Create,
                                   { saved_filter: state.merge(name: params[:name]) }, current_user)
  end
end
