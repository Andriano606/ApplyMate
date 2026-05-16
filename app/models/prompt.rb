# frozen_string_literal: true

class Prompt < ApplicationRecord
  REQUIRED_PLACEHOLDERS = {
    'fill_form'   => %w[PLACEHOLDER_VACANCY_CONTEXT PLACEHOLDER_USER_EXPERIENCE PLACEHOLDER_FORM_FIELDS],
    'generate_cv' => %w[PLACEHOLDER_USER_PROFILE PLACEHOLDER_VACANCY_TITLE PLACEHOLDER_VACANCY_DESCRIPTION]
  }.freeze

  belongs_to :user

  has_many :fill_form_applies, class_name: 'Apply', foreign_key: :fill_form_prompt_id, dependent: :nullify, inverse_of: :fill_form_prompt
  has_many :generate_cv_applies, class_name: 'Apply', foreign_key: :generate_cv_prompt_id, dependent: :nullify, inverse_of: :generate_cv_prompt
  has_many :vacancy_cvs, foreign_key: :generate_cv_prompt_id, dependent: :destroy, inverse_of: :generate_cv_prompt
  has_many :vacancy_forms, foreign_key: :fill_form_prompt_id, dependent: :destroy, inverse_of: :fill_form_prompt
  has_many :default_fill_form_users, class_name: 'User', foreign_key: :default_fill_form_prompt_id, dependent: :nullify, inverse_of: :default_fill_form_prompt
  has_many :default_generate_cv_users, class_name: 'User', foreign_key: :default_generate_cv_prompt_id, dependent: :nullify, inverse_of: :default_generate_cv_prompt

  enum :prompt_type, { fill_form: 0, generate_cv: 1 }

  validates :name, :prompt_type, :content, presence: true
  validate :required_placeholders_present

  private

  def required_placeholders_present
    return if prompt_type.blank? || content.blank?

    missing = (REQUIRED_PLACEHOLDERS[prompt_type] || []).reject { |ph| content.include?(ph) }
    return if missing.empty?

    errors.add(:content, I18n.t('prompt.errors.missing_placeholders', placeholders: missing.join(', ')))
  end
end
