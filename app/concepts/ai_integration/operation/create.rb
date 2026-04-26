# frozen_string_literal: true

class AiIntegration::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.ai_integrations.build
    authorize! model, :create?

    form_object = AiIntegration::FormObject::Create.new(params[:ai_integration])
    parse_validate_sync(form_object, model)
    model.save!
    notice(I18n.t('ai_integration.create.success'))
  end
end
