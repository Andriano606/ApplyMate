# frozen_string_literal: true

class VacancyQuestion::Component::NewModal < ApplyMate::Component::Base
  def initialize(vacancy:, vacancy_question:, **)
    @vacancy          = vacancy
    @vacancy_question = vacancy_question
  end
end
