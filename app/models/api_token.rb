# frozen_string_literal: true

class ApiToken < ApplicationRecord
  belongs_to :user

  has_secure_token :token

  validates :user, presence: true

  def touch_used!
    update_column(:last_used_at, Time.current)
  end
end
