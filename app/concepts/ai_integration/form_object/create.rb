# frozen_string_literal: true

class AiIntegration::FormObject::Create < ApplyMate::FormObject::Base
  property :provider
  property :api_key
  property :model

  validates :provider, :api_key, :model, presence: true
  validate :validate_api_key, if: -> { api_key.present? }

  private

  def validate_api_key
    Ai::GeminiClient.validate_api_key!(api_key:)
  rescue StandardError
    errors.add(:api_key, I18n.t('ai_integration.errors.invalid_api_key'))
  end
end
