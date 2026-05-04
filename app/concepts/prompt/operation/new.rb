# frozen_string_literal: true

class Prompt::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = current_user.prompts.build

    if params[:prompt].present?
      form_object = Prompt::FormObject::Create.new(params[:prompt])
      form_object.sync_to model

      form_object.content = if model.prompt_type_changed? && model.fill_form?
                              Apply::Ai::Prompt::Djinni::FillForm::PROMPT_TEMPLATE
      else
                              Apply::Ai::Prompt::Djinni::GenerateCv::PROMPT_TEMPLATE
      end
      form_object.sync_to model
    end

    authorize! model, :new?
  end
end
