# frozen_string_literal: true

class Source < ApplicationRecord
  SCRAPERS = %w[ApplyMate::Scraper::Dou ApplyMate::Scraper::Djinni].freeze

  has_one_attached :logo
  has_many :vacancies, dependent: :destroy
  has_many :source_profiles, dependent: :destroy

  validates :name, presence: true
  validates :base_url, presence: true
  validates :logo, presence: true
  validates :scraper, presence: true, inclusion: { in: SCRAPERS.map(&:to_s) }

  def build_scraper
    self.scraper.constantize.new(self, ApplyMate::Client::AsyncHttp.new)
  end
end
