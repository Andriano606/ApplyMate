# frozen_string_literal: true

class Mcp::Tool::SetVacancyHidden < Mcp::Tool::Base
  tool_name 'set_vacancy_hidden'
  title 'Hide or restore a vacancy'
  description <<~TEXT
    Hide a vacancy for the user (same as the hide button in the ApplyMate web UI) or restore it
    with hidden: false. Hidden vacancies are left out of search_vacancies by default — handy for
    marking vacancies as already reviewed. Idempotent.
  TEXT
  input_schema(
    properties: {
      id: { type: 'string', description: 'Vacancy id from search_vacancies.' },
      hidden: { type: 'boolean', description: 'true hides (default), false restores.' }
    },
    required: [ 'id' ],
    additionalProperties: false
  )
  annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)

  def self.call(id:, server_context:, hidden: true, **)
    run(Mcp::Operation::SetVacancyHidden, server_context, { id:, hidden: }) do |model|
      { id: model.vacancy.to_param, hidden: model.hidden }
    end
  end
end
