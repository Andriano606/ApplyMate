# frozen_string_literal: true

class AiIntegration::Component::OllamaForm < ApplyMate::Component::Base
  def initialize(form:, ai_integration:)
    @form = form
    @ai_integration = ai_integration
  end

  private

  def available_models
    return [] unless @ai_integration.host.present?
    @available_models ||= ApplyMate::Ai::Client::Ollama.new(host: @ai_integration.host).list_models
  rescue StandardError
    []
  end

  def host_valid?
    @ai_integration.host.present? && available_models.any?
  end
end
