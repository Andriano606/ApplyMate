# frozen_string_literal: true

class VacancyQuestion < ApplicationRecord
  belongs_to :vacancy
  belongs_to :ai_integration
  belongs_to :user_profile
  has_one    :user, through: :user_profile
  belongs_to :fill_form_prompt, class_name: 'Prompt'

  validates :question, presence: true
end
