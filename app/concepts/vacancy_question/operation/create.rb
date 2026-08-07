# frozen_string_literal: true

class VacancyQuestion::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy          = Vacancy.find(params[:vacancy_id])
    vacancy_question = vacancy.vacancy_questions.build(
      question:            params.dig(:vacancy_question, :question),
      user_profile_id:     params.dig(:vacancy_question, :user_profile_id),
      ai_integration_id:   params.dig(:vacancy_question, :ai_integration_id),
      fill_form_prompt_id: params.dig(:vacancy_question, :fill_form_prompt_id)
    )
    authorize! vacancy_question, :create?
    vacancy_question.save!
    VacancyQuestion::Job::Create.perform_later(vacancy_question.id)
    notice(I18n.t('vacancy.update.generate_answer_started'))
    self.model = ApplyMate::Operation::Struct.new(vacancy:, vacancy_question:)
  end
end
