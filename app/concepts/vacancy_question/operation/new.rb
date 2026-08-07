# frozen_string_literal: true

class VacancyQuestion::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy          = Vacancy.find(params[:vacancy_id])
    vacancy_question = vacancy.vacancy_questions.build(
      user_profile_id:     current_user.default_profile_id,
      ai_integration_id:   current_user.default_ai_integration_id,
      fill_form_prompt_id: current_user.default_fill_form_prompt_id
    )
    authorize! vacancy_question, :new?

    self.model = ApplyMate::Operation::Struct.new(vacancy:, vacancy_question:)
  end
end
