# frozen_string_literal: true

class AiIntegration::FormObject::Create < ApplyMate::FormObject::Base
  property :provider
  property :api_key
  property :host
  property :model

  validates :provider, :model, presence: true
  validates :api_key, presence: true, unless: :ollama_provider?
  validates :host, presence: true, if: :ollama_provider?
  validate :validate_gemini_api_key, if: -> { provider == 'gemini' && api_key.present? }
  validate :validate_ollama_connection, if: -> { provider == 'ollama' && host.present? }

  private

  def ollama_provider?
    provider == 'ollama'
  end

  def validate_gemini_api_key
    Ai::GeminiClient.validate_api_key!(api_key:)
  rescue StandardError
    errors.add(:api_key, I18n.t('ai_integration.errors.invalid_api_key'))
  end

  def validate_ollama_connection
    models = Ai::OllamaClient.new(host:).list_models
    errors.add(:host, I18n.t('ai_integration.errors.connection_failed')) if models.empty?
  end
end
