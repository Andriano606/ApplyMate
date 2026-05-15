# frozen_string_literal: true

class VacancyCv < ApplicationRecord
  belongs_to :vacancy
  belongs_to :ai_integration
  belongs_to :user_profile
  has_one    :user, through: :user_profile
  belongs_to :generate_cv_prompt, class_name: 'Prompt'

  has_one_attached :cv

  def cv_filename
    name = user_profile.name.to_s.strip
    return 'CV.pdf' if name.blank?

    "#{name.gsub(/\s+/, '_')}_CV.pdf"
  end
end
