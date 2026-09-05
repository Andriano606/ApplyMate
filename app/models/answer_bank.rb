# frozen_string_literal: true

# One reusable answer of a user profile: either a canonical role (email, phone,
# notice_period, …) or a cached custom question ("How many years of React?").
# Filled by ResolveValues (AI answers are cached back with source ai_generated)
# and editable by the user later — manual answers are the source of truth.
class AnswerBank < ApplicationRecord
  belongs_to :user_profile

  enum :source, { manual: 0, ai_generated: 1, imported: 2 }

  validates :role, presence: true
  validates :answer, presence: true, allow_blank: false
  validates :question, presence: true, if: :custom_question?

  def self.normalize_question(text)
    text.to_s.downcase.squish
  end

  def custom_question?
    role == 'custom_question'
  end
end
