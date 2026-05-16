# frozen_string_literal: true

class VacancyForm::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy      = Vacancy.find(params[:vacancy_id])
    vacancy_form = vacancy.vacancy_forms.build(
      user_profile_id:     params.dig(:vacancy_form, :user_profile_id),
      ai_integration_id:   params.dig(:vacancy_form, :ai_integration_id),
      fill_form_prompt_id: params.dig(:vacancy_form, :fill_form_prompt_id)
    )
    authorize! vacancy_form, :create?
    vacancy_form.save!
    VacancyForm::Job::Create.perform_later(vacancy_form.id, current_user.id)
    notice(I18n.t('vacancy_form.create.success'))

    self.model = ApplyMate::Operation::Struct.new(vacancy:, vacancy_form:)
  end
end
