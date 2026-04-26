# frozen_string_literal: true

class AiIntegration::Component::Index < ApplyMate::Component::Base
  def initialize(ai_integrations:, **)
    @ai_integrations = ai_integrations
  end

  private

  def header_opts
    { title: I18n.t('ai_integration.index.title') }
  end
end
