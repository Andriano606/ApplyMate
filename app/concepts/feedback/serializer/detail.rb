# frozen_string_literal: true

# A feedback as the MCP tools return it.
class Feedback::Serializer::Detail < ApplyMate::Serializer::Base
  def call
    {
      id: @model.to_param,
      rating: @model.rating,
      sentiment: @model.sentiment,
      comment: @model.body,
      posted_via: @model.posted_via,
      created_at: @model.created_at,
      updated_at: @model.updated_at
    }
  end
end
