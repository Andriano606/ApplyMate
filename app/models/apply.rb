# frozen_string_literal: true

class Apply < ApplicationRecord
  belongs_to :user
  belongs_to :vacancy
  belongs_to :user_profile
  belongs_to :ai_integration
  belongs_to :source_profile
  belongs_to :fill_form_prompt, class_name: 'Prompt', optional: true
  belongs_to :generate_cv_prompt, class_name: 'Prompt', optional: true

  validate :source_must_match

  has_one_attached :cv
  has_one_attached :screenshot

  jsonb_accessor :form_data,
    action:           :string, # form action URL (resolved absolute)
    http_method:      :string, # HTTP method extracted from the form element ('post', 'get')
    submit_selector:  :string, # CSS selector for the submit button
    submit_text:      :string, # visible text of the submit button, used for disambiguation
    external_url:     :string, # canonical URL of the employer's application page
    trigger_selector: :string, # CSS selector to click before the form appears (e.g. "Apply" button)
    cookies:          :string, # cookies captured at form-fetch time, forwarded on HTTP submission
    inputs:           :value   # Array<{ name, selector, form_index, tag, type, label, placeholder, value, options? }>

  jsonb_accessor :filled_form_data,
    filled_inputs: :value  # same shape as inputs, with AI-filled values

  enum :apply_type, { unknown: 0, external: 1, internal: 2 }

  enum :status, {
    checking_applyble: 9,
    failed_checking_applyble: 10,
    fetching_apply_type: 16,
    failed_fetching_apply_type: 17,
    fetching_details: 7,
    failed_fetching_details: 8,
    fetching_form: 11,
    failed_fetching_form: 12,
    filling_form: 13,
    failed_filling_form: 14,
    generating_cv: 1,
    failed_generating_cv: 5,
    sending_cv: 3,
    failed_sending_cv: 6,
    completed: 4
  }

  def in_progress?
    checking_applyble? || fetching_apply_type? || fetching_details? ||
      fetching_form? || filling_form? || generating_cv? ||
      sending_cv?
  end

  def failed?
    failed_checking_applyble? || failed_fetching_apply_type? || failed_fetching_details? ||
      failed_fetching_form? || failed_filling_form? || failed_generating_cv? || failed_sending_cv?
  end

  private

  def source_must_match
    return if vacancy.blank? || source_profile.blank?

    return if source_profile.source_id == vacancy.source_id

    errors.add(:source_profile, 'must belong to the same source as the vacancy')
  end
end
