# frozen_string_literal: true

class Apply::FormObject::Create < ApplyMate::FormObject::Base
  property :vacancy_id
  property :user_profile_id
  property :ai_integration_id
  property :source_profile_id
  property :fill_form_prompt_id
  property :generate_cv_prompt_id

  validates :vacancy_id, :user_profile_id, :ai_integration_id, :source_profile_id,
            :fill_form_prompt_id, :generate_cv_prompt_id, presence: true
end
