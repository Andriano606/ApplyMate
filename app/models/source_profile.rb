# frozen_string_literal: true

class SourceProfile < ApplicationRecord
  belongs_to :user
  belongs_to :source

  enum :auth_method, { session_id: 0 }

  validates :name, :auth_method, presence: true
end
