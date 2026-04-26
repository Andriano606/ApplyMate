# frozen_string_literal: true

class AiIntegration::Component::GeminiForm < ApplyMate::Component::Base
  def initialize(form:, ai_integration:)
    @form = form
    @ai_integration = ai_integration
  end

  private

  def available_models
    @available_models ||= Ai::GeminiClient.new(api_key: @ai_integration.api_key).list_models
  rescue StandardError
    []
  end

  def api_key_valid?
    @ai_integration.api_key.present? && available_models.any?
  end
end
