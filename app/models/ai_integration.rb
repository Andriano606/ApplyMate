# frozen_string_literal: true

class AiIntegration < ApplicationRecord
  PROVIDERS = [ :gemini, :ollama, :gemini_scraping ].freeze
  PROVIDER_CLIENTS = {
    'gemini' => ApplyMate::Ai::Client::Gemini,
    'ollama' => ApplyMate::Ai::Client::Ollama,
    'gemini_scraping' => ApplyMate::Ai::Client::GeminiScraping
  }.freeze

  attr_accessor :fetch_models

  belongs_to :user
  has_many :users_as_default,
           class_name: 'User',
           foreign_key: 'default_ai_integration_id',
           dependent: :nullify
  has_many :applies,
           class_name: 'Apply',
           foreign_key: 'ai_integration_id',
           dependent: :destroy

  encrypts :api_key

  validates :provider, presence: true, inclusion: { in: PROVIDERS.map(&:to_s) }
  validates :api_key, presence: true, if: :gemini?
  validates :host, presence: true, if: :ollama?
  validates :model, presence: true, unless: :gemini_scraping?

  def ollama?
    provider == 'ollama'
  end

  def gemini?
    provider == 'gemini'
  end

  def gemini_scraping?
    provider == 'gemini_scraping'
  end

  def label
    "#{provider.capitalize.humanize} #{model.present? ? "#{model.humanize}" : ''}"
  end
end
