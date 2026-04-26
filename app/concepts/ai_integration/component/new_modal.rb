# frozen_string_literal: true

class AiIntegration::Component::NewModal < ApplyMate::Component::Base
  PROVIDER_UI = {
    gemini: { label: 'Gemini', icon_name: :google }
  }.freeze

  def initialize(ai_integration:, **)
    @ai_integration = ai_integration
  end
end
