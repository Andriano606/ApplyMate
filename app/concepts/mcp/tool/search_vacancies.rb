# frozen_string_literal: true

class Mcp::Tool::SearchVacancies < Mcp::Tool::Base
  tool_name 'search_vacancies'
  title 'Search vacancies'
  description <<~TEXT
    Full-text search over the live vacancies ApplyMate keeps in sync from job boards (DOU, Djinni, …).
    Phrases are matched in the title, company name and description. Results come newest first
    (or by relevance) and are paginated; each hit has a short snippet — call get_vacancies with
    the ids to read the full description.

    `query` syntax (one boolean expression):
      - words next to each other form one phrase: `ruby on rails`
      - AND: `і`, `та`, `and`, `&&`, `&`; OR: `або`, `or`, `||`, `|` (case-insensitive)
      - AND binds tighter than OR; use parentheses: `embedded and (remote or віддалено)`
      - quotes make an exact phrase, even of operator words: `"react native" or flutter`
    Vacancies are mostly in Ukrainian or English, so search both spellings when it matters
    (`віддалено or remote`).
  TEXT
  input_schema(
    properties: {
      query: { type: 'string', description: 'Boolean search expression (see the tool description). Omit to list everything.' },
      exclude: {
        type: 'array', items: { type: 'string' },
        description: 'Drop vacancies matching any of these. A single word also matches as a prefix (`junior` drops `juniors`).'
      },
      sources: {
        type: 'array', items: { type: 'string' },
        description: 'Only these job boards — names or ids from list_sources.'
      },
      saved_filter_id: {
        type: 'string',
        description: "Start from one of the user's saved filters (list_saved_filters); `query` and `exclude` narrow it further."
      },
      sort: { type: 'string', enum: Vacancy::Operation::Search::SORTS.keys, description: 'Default `newest`.' },
      page: { type: 'integer', minimum: 1, description: 'Default 1.' },
      per_page: {
        type: 'integer', minimum: 1, maximum: Vacancy::Operation::Search::MAX_PER_PAGE,
        description: "Default #{Mcp::Operation::SearchVacancies::DEFAULT_PER_PAGE}."
      }
    },
    additionalProperties: false
  )
  annotations(**READ_ONLY)

  def self.call(server_context:, **params)
    run(Mcp::Operation::SearchVacancies, server_context, params) do |vacancies|
      { vacancies: vacancies.map { |vacancy| Vacancy::Serializer::Summary.call(vacancy) },
        pagination: pagination(vacancies) }
    end
  end
end
