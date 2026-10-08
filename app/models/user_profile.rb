# frozen_string_literal: true

class UserProfile < ApplicationRecord
  belongs_to :user
  has_many :applies,           dependent: :destroy
  has_many :vacancy_cvs,       dependent: :destroy
  has_many :vacancy_questions, dependent: :destroy
  has_many :users_as_default,
           class_name: 'User',
           foreign_key: 'default_profile_id',
           dependent: :nullify

  validates :name, presence: true
  validates :cv, presence: true

  # facts = { 'ai' => extracted from the CV, 'user' => edited by the user }; a user value wins.
  def fact(key)
    facts_hash = facts || {}
    facts_hash.dig('user', key.to_s).presence || facts_hash.dig('ai', key.to_s).presence
  end
end
