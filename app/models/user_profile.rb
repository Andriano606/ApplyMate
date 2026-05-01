# frozen_string_literal: true

class UserProfile < ApplicationRecord
  belongs_to :user
  has_many :users_as_default,
           class_name: 'User',
           foreign_key: 'default_profile_id',
           dependent: :nullify

  validates :name, presence: true
  validates :cv, presence: true
end
