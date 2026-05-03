# frozen_string_literal: true

class AiIntegration::FormObject::Create < ApplyMate::FormObject::Base
  property :provider
  property :api_key
  property :host
  property :model

  validates :provider, presence: true
  validates :model, presence: true, unless: :gemini_scraping_provider?
  validates :api_key, presence: true, if: :gemini_provider?
  validates :host, presence: true, if: :ollama_provider?
  validate :validate_gemini_api_key, if: -> { provider == 'gemini' && api_key.present? }
  validate :validate_ollama_connection, if: -> { provider == 'ollama' && host.present? }

  private

  def ollama_provider?
    provider == 'ollama'
  end

  def gemini_provider?
    provider == 'gemini'
  end

  def gemini_scraping_provider?
    provider == 'gemini_scraping'
  end

  def validate_gemini_api_key
    ApplyMate::Ai::Client::Gemini.validate_api_key!(api_key:)
  rescue StandardError
    errors.add(:api_key, I18n.t('ai_integration.errors.invalid_api_key'))
  end

  def validate_ollama_connection
    models = ApplyMate::Ai::Client::Ollama.new(host:).list_models
    errors.add(:host, I18n.t('ai_integration.errors.connection_failed')) if models.empty?
  end
end
