# frozen_string_literal: true

# A saved filter as the MCP tools return it — the same shape create/update_saved_filter accept.
class SavedFilter::Serializer::Detail < ApplyMate::Serializer::Base
  def call
    {
      id: @model.to_param,
      name: @model.name,
      include_tags: @model.include_tags,
      include_ops: @model.include_ops,
      exclude_tags: @model.exclude_tags
    }
  end
end
