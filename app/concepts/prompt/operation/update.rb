# frozen_string_literal: true

class Prompt::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.prompts.find(params[:id])
    authorize! model, :update?

    form_object = Prompt::FormObject::Create.new(params[:prompt])
    parse_validate_sync(form_object, model)
    model.save!
    notice(I18n.t('prompt.update.success'))
  end
end
