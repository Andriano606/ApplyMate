# frozen_string_literal: true

class VacancyCv::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy    = Vacancy.find(params[:vacancy_id])
    vacancy_cv = vacancy.vacancy_cvs.build(
      user_profile_id:       current_user.default_profile_id,
      ai_integration_id:     current_user.default_ai_integration_id,
      generate_cv_prompt_id: current_user.default_generate_cv_prompt_id
    )
    authorize! vacancy_cv, :new?

    self.model = ApplyMate::Operation::Struct.new(vacancy:, vacancy_cv:)
  end
end
