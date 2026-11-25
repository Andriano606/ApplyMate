# frozen_string_literal: true

class Mcp::Tool::ListSavedFilters < Mcp::Tool::Base
  tool_name 'list_saved_filters'
  title 'List saved filters'
  description <<~TEXT
    The user's saved search filters. Pass an id as search_vacancies `saved_filter_id` to run one.
    include_tags are boolean expressions joined by include_ops: `and`, `or`, or `g_or` (joins two
    neighbours into one parenthesised OR group); precedence is g_or, then and, then or.
    exclude_tags drop matching vacancies. create_saved_filter / update_saved_filter /
    delete_saved_filter manage them.
  TEXT
  input_schema(properties: {}, additionalProperties: false)
  annotations(**READ_ONLY)

  def self.call(server_context:, **)
    run(Mcp::Operation::ListSavedFilters, server_context) do |model|
      { saved_filters: model.map { |filter| SavedFilter::Serializer::Detail.call(filter) } }
    end
  end
end
