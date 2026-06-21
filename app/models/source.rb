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
    klass = scraper.constantize
    # Use the source's own client (Dou → ImpersonateHttp) so the apply flow reaches a
    # Cloudflare-protected vacancy page too, not just the sync — plain AsyncHttp gets 403.
    klass.new(self, klass.http_client_class.new)
  end
end
