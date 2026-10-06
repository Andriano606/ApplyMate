# frozen_string_literal: true

# One question/answer card of the vacancy page. Live-updated through VacancyQuestion::TurboHandler::AnswerReady.
class VacancyQuestion::Component::AnswerContent < ApplyMate::Component::Base
  def initialize(vacancy_question:)
    @vacancy_question = vacancy_question
    @vacancy          = vacancy_question.vacancy
  end

  private

  def answered?
    @vacancy_question.answer.present?
  end
end
