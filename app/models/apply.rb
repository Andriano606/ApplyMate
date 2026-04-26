# frozen_string_literal: true

class Apply < ApplicationRecord
  belongs_to :user
  belongs_to :vacancy
  belongs_to :user_profile
  belongs_to :ai_integration

  has_one_attached :cv

  enum :status, {
    pending: 0,
    generating_cv: 1,
    cv_generated: 2,
    sending_cv: 3,
    completed: 4,
    failed_cv_generation: 5,
    failed_cv_sending: 6
  }

  def in_progress?
    pending? || generating_cv? || cv_generated? || sending_cv?
  end

  def failed?
    failed_cv_generation? || failed_cv_sending?
  end
end
