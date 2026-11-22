# frozen_string_literal: true

class Mcp::Tool::ListSources < Mcp::Tool::Base
  tool_name 'list_sources'
  title 'List job boards'
  description 'The job boards ApplyMate syncs vacancies from, with how many live vacancies each has. ' \
              'Use a name or id in search_vacancies `sources`.'
  input_schema(properties: {}, additionalProperties: false)
  annotations(**READ_ONLY)

  def self.call(server_context:, **)
    run(Mcp::Operation::ListSources, server_context) do |model|
      {
        sources: model.map do |row|
          { id: row.source.to_param, name: row.source.name, base_url: row.source.base_url,
            listing_url: row.source.listing_url, vacancy_count: row.count }
        end
      }
    end
  end
end
