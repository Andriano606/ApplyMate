# frozen_string_literal: true

class AiIntegration::Component::Modal < ApplyMate::Component::Base
  PROVIDER_UI = {
    gemini: { label: 'Gemini', icon_name: :google },
    ollama: { label: 'Ollama', icon_name: :cube },
    gemini_scraping: { label: 'Gemini (Scraping)', icon_name: :google }
  }.freeze

  def initialize(ai_integration:, **)
    @ai_integration = ai_integration
  end
end
