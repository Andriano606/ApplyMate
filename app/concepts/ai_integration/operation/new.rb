# frozen_string_literal: true

class AiIntegration::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.ai_integrations.build

    if params[:ai_integration].present?
      form_object = AiIntegration::FormObject::Create.new(params[:ai_integration])
      form_object.provider ||= AiIntegration::PROVIDERS.first.to_s
      form_object.sync_to model
    end

    authorize! model, :new?
  end
end
