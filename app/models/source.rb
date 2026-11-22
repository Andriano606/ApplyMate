# frozen_string_literal: true

class Source < ApplicationRecord
  SCRAPERS = %w[ApplyMate::Scraper::Dou ApplyMate::Scraper::Djinni].freeze

  has_one_attached :logo
  has_many :vacancies, dependent: :destroy

  validates :name, presence: true
  validates :base_url, presence: true
  validates :logo, presence: true
  validates :scraper, presence: true, inclusion: { in: SCRAPERS.map(&:to_s) }

  # Public listing page of this source (Dou → /vacancies/, Djinni → /jobs/), owned by
  # the scraper so the URL lives next to the code that scrapes it.
  def listing_url
    scraper.constantize.listing_url(self)
  end
end
