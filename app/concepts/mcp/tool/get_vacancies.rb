# frozen_string_literal: true

class Mcp::Tool::GetVacancies < Mcp::Tool::Base
  tool_name 'get_vacancies'
  title 'Get vacancies'
  description <<~TEXT
    Everything ApplyMate stores about the given vacancies: title, company, source job board,
    original URL, the full plain-text description, when it was first seen (created_at) and last
    refreshed by a sync (updated_at), and whether the user hid it. Ids come from search_vacancies.
    Ids that no longer exist (the vacancy was closed and removed by a sync) are listed in missing_ids.
  TEXT
  input_schema(
    properties: {
      ids: {
        type: 'array', items: { type: 'string' }, minItems: 1, maxItems: Mcp::Operation::GetVacancies::MAX_IDS,
        description: 'Vacancy ids from search_vacancies.'
      },
      include_html: {
        type: 'boolean',
        description: 'Also return description_html, the original markup (headings, lists, links). Default false.'
      }
    },
    required: [ 'ids' ],
    additionalProperties: false
  )
  annotations(**READ_ONLY)

  def self.call(ids:, server_context:, include_html: false, **)
    run(Mcp::Operation::GetVacancies, server_context, { ids: }) do |model|
      {
        vacancies: model.vacancies.map do |vacancy|
          Vacancy::Serializer::Detail.call(vacancy, include_html:)
                                     .merge(hidden: model.hidden_vacancy_ids.include?(vacancy.id))
        end,
        missing_ids: model.missing_ids
      }
    end
  end
end
