# frozen_string_literal: true

class AiIntegration::Operation::Edit < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.ai_integrations.find(params[:id])
    authorize! model, :edit?

    if params[:ai_integration].present?
      form_object = AiIntegration::FormObject::Update.new(params[:ai_integration], model)
      form_object.sync_to model
    end
  end
end
