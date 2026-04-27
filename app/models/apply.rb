# frozen_string_literal: true

class Apply < ApplicationRecord
  belongs_to :user
  belongs_to :vacancy
  belongs_to :user_profile
  belongs_to :ai_integration
  belongs_to :source_profile

  validate :source_must_match

  has_one_attached :cv

  enum :status, {
    pending: 0,
    generating_cv: 1,
    cv_generated: 2,
    sending_cv: 3,
    completed: 4,
    failed_cv_generation: 5,
    failed_cv_sending: 6,
    fetching_details: 7,
    failed_fetching_details: 8,
    checking_applyble: 9,
    failed_checking_applyble: 10,
    fetching_form: 11,
    failed_fetching_form: 12,
    filling_form: 13,
    failed_filling_form: 14
  }

  def in_progress?
    pending? || fetching_details? || generating_cv? || cv_generated? || sending_cv? || fetching_form? || filling_form?
  end

  def failed?
    failed_fetching_details? || failed_cv_generation? || failed_cv_sending? || failed_fetching_form? || failed_filling_form?
  end

  private

  def source_must_match
    return if vacancy.blank? || source_profile.blank?

    return if source_profile.source_id == vacancy.source_id

    errors.add(:source_profile, 'must belong to the same source as the vacancy')
  end
end
