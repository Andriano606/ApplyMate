# frozen_string_literal: true

class SourceProfile < ApplicationRecord
  belongs_to :user
  belongs_to :source
  has_many :applies, dependent: :destroy
  has_many :users_as_default,
          class_name: 'User',
          foreign_key: 'default_source_profile_id',
          dependent: :nullify

  enum :auth_method, { session_id: 0 }

  validates :name, :auth_method, presence: true
end
