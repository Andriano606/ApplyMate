# frozen_string_literal: true

class VacancyQuestion::Component::AnswerContent < ApplyMate::Component::Base
  def initialize(vacancy_question:)
    @vacancy_question = vacancy_question
    @vacancy          = vacancy_question.vacancy
  end

  private

  def title
    @vacancy_question.question.truncate(80)
  end
end
