# frozen_string_literal: true

class Prompt::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.prompts.build
    authorize! model, :create?

    form_object = Prompt::FormObject::Create.new(params[:prompt])
    parse_validate_sync(form_object, model)
    model.save!
    notice(I18n.t('prompt.create.success'))
  end
end
