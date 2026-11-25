# frozen_string_literal: true

class Mcp::Tool::UpdateSavedFilter < Mcp::Tool::Base
  tool_name 'update_saved_filter'
  title 'Edit a saved filter'
  description <<~TEXT
    Rename and/or change one of the user's saved filters (id from list_saved_filters). Send only
    what changes: omitted fields keep their values; an empty array clears that list. New
    include_tags without include_ops are joined with `and` (the old ops no longer line up).
    Saving also makes it the filter the web search opens with. Returns the saved filter.

    #{Mcp::Tool::CreateSavedFilter::SYNTAX}
    Only call this when the user asks to change a filter, and check the result with
    search_vacancies saved_filter_id.
  TEXT
  input_schema(
    properties: {
      id: { type: 'string', description: 'Saved filter id from list_saved_filters.' },
      name: { type: 'string', minLength: 1, maxLength: Mcp::Tool::CreateSavedFilter::NAME_MAX_LENGTH },
      include_tags: Mcp::Tool::CreateSavedFilter::TAGS_SCHEMA,
      include_ops: Mcp::Tool::CreateSavedFilter::OPS_SCHEMA,
      exclude_tags: Mcp::Tool::CreateSavedFilter::TAGS_SCHEMA
    },
    required: %w[id],
    additionalProperties: false
  )
  annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true, open_world_hint: false)

  def self.call(server_context:, **arguments)
    run(Mcp::Operation::UpdateSavedFilter, server_context, Mcp::Tool::CreateSavedFilter.filter_params(arguments)) do |model|
      { saved_filter: SavedFilter::Serializer::Detail.call(model) }
    end
  end
end
