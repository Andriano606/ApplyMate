# frozen_string_literal: true

class Source < ApplicationRecord
  has_one_attached :logo

  validates :name, presence: true
  validates :base_url, presence: true
  validates :logo, presence: true
end
