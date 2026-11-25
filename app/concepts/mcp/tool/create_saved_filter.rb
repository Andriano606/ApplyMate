# frozen_string_literal: true

class Mcp::Tool::CreateSavedFilter < Mcp::Tool::Base
  NAME_MAX_LENGTH = 100
  TAGS_MAX = 50

  # How the stored state is searched — shared with update_saved_filter.
  SYNTAX = <<~TEXT
    How a saved filter matches (the same rules as search_vacancies):
    - include_tags: each tag is a boolean expression of phrases matched in the title, company
      name and description — words next to each other form one phrase; and/і/та, or/або,
      parentheses, quotes for an exact phrase. One tag holding the whole expression is simplest.
    - include_ops join neighbouring include_tags: `and`, `or`, or `g_or` (two neighbours become one
      parenthesised OR group); precedence g_or, then and, then or. Exactly one op fewer than
      include_tags; omit include_ops to join every tag with `and`.
    - exclude_tags drop vacancies. A one-word tag matches as a word prefix anywhere in the text
      (`junior` also drops `juniors`), so prefer multi-word phrases; longer tags match as a phrase.
    - Tags cannot contain commas (the search splits them): use separate tags or `or`.
  TEXT

  TAGS_SCHEMA = { type: 'array', maxItems: TAGS_MAX, items: { type: 'string', minLength: 1 } }.freeze
  OPS_SCHEMA  = { type: 'array', maxItems: TAGS_MAX, items: { type: 'string', enum: Vacancy::Operation::BuildSearchQuery::OPS } }.freeze

  tool_name 'create_saved_filter'
  title 'Create a saved filter'
  description <<~TEXT
    Save a new search filter for the user — it appears among the presets above the web search bar
    (and becomes the one the web search opens with) and in list_saved_filters. Returns the saved
    filter with its id. Names are unique per user.

    #{SYNTAX}
    Only call this when the user asks to save a filter. Try the expression with search_vacancies
    (query + exclude) first and show the user what it finds; afterwards check it with
    search_vacancies saved_filter_id.
  TEXT
  input_schema(
    properties: {
      name: { type: 'string', minLength: 1, maxLength: NAME_MAX_LENGTH, description: 'Shown on the preset pill.' },
      include_tags: TAGS_SCHEMA.merge(description: 'What vacancies must match.'),
      include_ops: OPS_SCHEMA.merge(description: 'One op between each pair of neighbouring include_tags.'),
      exclude_tags: TAGS_SCHEMA.merge(description: 'What drops a vacancy.')
    },
    required: %w[name],
    additionalProperties: false
  )
  annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: false, open_world_hint: false)

  def self.call(server_context:, **arguments)
    run(Mcp::Operation::CreateSavedFilter, server_context, filter_params(arguments)) do |model|
      { saved_filter: SavedFilter::Serializer::Detail.call(model) }
    end
  end

  # Only the arguments the model actually sent: an omitted key means "keep" on update.
  def self.filter_params(arguments)
    arguments.slice(:id, :name, :include_tags, :include_ops, :exclude_tags)
  end
end
