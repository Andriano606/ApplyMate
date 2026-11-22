# frozen_string_literal: true

# A vacancy as one search hit: enough to judge relevance and open it, with a
# short plain-text snippet instead of the full description (see Detail).
class Vacancy::Serializer::Summary < ApplyMate::Serializer::Base
  SNIPPET_LENGTH = 300

  def call
    {
      id: @model.to_param,
      title: @model.title,
      company_name: @model.company_name,
      source: @model.source.name,
      url: @model.url,
      snippet: @model.description.to_s.squish.truncate(SNIPPET_LENGTH),
      created_at: @model.created_at,
      updated_at: @model.updated_at
    }
  end
end
