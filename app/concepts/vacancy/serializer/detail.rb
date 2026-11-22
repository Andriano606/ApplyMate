# frozen_string_literal: true

# Everything stored about a vacancy. description is the plain-text projection of
# description_html; the markup is only included on request because it roughly
# doubles the payload without adding information for a reader.
class Vacancy::Serializer::Detail < ApplyMate::Serializer::Base
  def initialize(model, include_html: false)
    super(model)
    @include_html = include_html
  end

  def self.call(model, include_html: false)
    new(model, include_html:).call
  end

  def call
    payload = {
      id: @model.to_param,
      title: @model.title,
      company_name: @model.company_name,
      company_icon_url: @model.company_icon_url,
      url: @model.url,
      external_id: @model.external_id,
      source: { id: @model.source.to_param, name: @model.source.name, base_url: @model.source.base_url },
      description: @model.description,
      created_at: @model.created_at,
      updated_at: @model.updated_at
    }
    payload[:description_html] = @model.description_html if @include_html
    payload
  end
end
