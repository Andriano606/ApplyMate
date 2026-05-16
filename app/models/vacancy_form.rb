# frozen_string_literal: true

class VacancyForm < ApplicationRecord
  belongs_to :vacancy
  belongs_to :user_profile
  belongs_to :ai_integration
  belongs_to :fill_form_prompt, class_name: 'Prompt'
  has_one    :user, through: :user_profile

  jsonb_accessor :form_data

  enum :status, {
    processing: 0,
    done:       1,
    failed:     2
  }
end
