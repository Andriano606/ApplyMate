# frozen_string_literal: true

class Prompt::FormObject::Create < ApplyMate::FormObject::Base
  property :name
  property :prompt_type
  property :content

  validates :name, :prompt_type, :content, presence: true
end
