# frozen_string_literal: true

class VacancyForm::Operation::New < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy      = Vacancy.find(params[:vacancy_id])
    vacancy_form = vacancy.vacancy_forms.build(
      user_profile_id:     current_user.default_profile_id,
      ai_integration_id:   current_user.default_ai_integration_id,
      fill_form_prompt_id: current_user.default_fill_form_prompt_id
    )
    authorize! vacancy_form, :new?

    self.model = ApplyMate::Operation::Struct.new(vacancy:, vacancy_form:)
  end
end
