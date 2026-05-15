# frozen_string_literal: true

class VacancyCv::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy    = Vacancy.find(params[:vacancy_id])
    vacancy_cv = vacancy.vacancy_cvs.build(
      user_profile_id:       params.dig(:vacancy_cv, :user_profile_id),
      ai_integration_id:     params.dig(:vacancy_cv, :ai_integration_id),
      generate_cv_prompt_id: params.dig(:vacancy_cv, :generate_cv_prompt_id)
    )
    authorize! vacancy_cv, :create?
    vacancy_cv.save!
    VacancyCv::Job::Create.perform_later(vacancy_cv.id, current_user.id)
    notice(I18n.t('vacancy.update.generate_cv_started'))

    self.model = ApplyMate::Operation::Struct.new(vacancy:, vacancy_cv:)
  end
end
