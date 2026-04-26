# frozen_string_literal: true

class AiIntegration::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.ai_integrations.find(params[:id])
    authorize! model, :update?

    form = AiIntegration::FormObject::Update.new(params[:ai_integration], model)
    parse_validate_sync(form)
    model.save!
    notice(I18n.t('ai_integration.update.success'))
  end
end
