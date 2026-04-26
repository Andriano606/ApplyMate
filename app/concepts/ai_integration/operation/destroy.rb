# frozen_string_literal: true

class AiIntegration::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.ai_integrations.find(params[:id])
    authorize! model, :destroy?
    model.destroy!
    notice(I18n.t('ai_integration.destroy.success'))
  end
end
