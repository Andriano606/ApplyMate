# frozen_string_literal: true

class Apply::FormObject::Create < ApplyMate::FormObject::Base
  property :vacancy_id
  property :user_profile_id
  property :ai_integration_id

  validates :vacancy_id, :user_profile_id, :ai_integration_id, presence: true
end
