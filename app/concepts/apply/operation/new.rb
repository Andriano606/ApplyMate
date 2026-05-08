# frozen_string_literal: true

class Apply::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy = Vacancy.find(params[:vacancy_id])
    self.model = Apply.new(
      vacancy: vacancy,
      user: current_user,
      user_profile_id: current_user.default_profile_id,
      ai_integration_id: current_user.default_ai_integration_id,
      source_profile_id: SourceProfile.default_for(current_user, vacancy.source)&.id,
      fill_form_prompt_id: current_user.default_fill_form_prompt_id,
      generate_cv_prompt_id: current_user.default_generate_cv_prompt_id
    )
    authorize! model, :new?
  end
end
