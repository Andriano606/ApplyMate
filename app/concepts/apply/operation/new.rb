# frozen_string_literal: true

class Apply::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = Apply.new(
      vacancy: Vacancy.find(params[:vacancy_id]),
      user: current_user,
      user_profile_id: current_user.default_profile_id,
      ai_integration_id: current_user.default_ai_integration_id,
      source_profile_id: current_user.default_source_profile_id,
      fill_form_prompt_id: current_user.default_fill_form_prompt_id,
      generate_cv_prompt_id: current_user.default_generate_cv_prompt_id
    )
    authorize! model, :new?
  end
end
