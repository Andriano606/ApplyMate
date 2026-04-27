# frozen_string_literal: true

class AiIntegration < ApplicationRecord
  PROVIDERS = [ :gemini, :ollama ].freeze
  PROVIDER_CLIENTS = {
    'gemini' => Ai::GeminiClient,
    'ollama' => Ai::OllamaClient
  }.freeze

  attr_accessor :fetch_models

  belongs_to :user

  encrypts :api_key

  validates :provider, presence: true, inclusion: { in: PROVIDERS.map(&:to_s) }
  validates :api_key, presence: true, unless: :ollama?
  validates :host, presence: true, if: :ollama?
  validates :model, presence: true

  def ollama?
    provider == 'ollama'
  end
end
