# frozen_string_literal: true

class VacancyForm::Job::Create < ApplicationJob
  queue_as :default

  def perform(vacancy_form_id, user_id)
    vacancy_form = VacancyForm.find(vacancy_form_id)
    sleep 3
    vacancy_form.update!(status: :done)
    VacancyForm::TurboHandler::Index.broadcast(vacancy_form)
  end
end
