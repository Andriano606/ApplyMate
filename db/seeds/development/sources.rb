# frozen_string_literal: true

SOURCES = [
  {
    name: 'Djinni',
    base_url: 'https://djinni.co/',
    scraper: 'ApplyMate::Scraper::Djinni',
    logo_filename: 'djinni-logo.webp',
    logo_content_type: 'image/webp'
  },
  {
    name: 'Dou',
    base_url: 'https://dou.ua/',
    scraper: 'ApplyMate::Scraper::Dou',
    logo_filename: 'dou-logo.png',
    logo_content_type: 'image/png'
  }
].freeze

SOURCES.each do |attrs|
  logo_path = Rails.root.join('db/seeds/development/sources', attrs[:logo_filename])
  payload = attrs.slice(:name, :base_url, :scraper)
  unless Source.find_by(name: attrs[:name])&.logo&.attached?
    payload[:logo] = { io: logo_path.open, filename: attrs[:logo_filename], content_type: attrs[:logo_content_type] }
  end
  sources.create unique_by: :name, **payload
end
