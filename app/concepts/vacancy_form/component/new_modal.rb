# frozen_string_literal: true

class VacancyForm::Component::NewModal < ApplyMate::Component::Base
  def initialize(vacancy:, vacancy_form:, **)
    @vacancy      = vacancy
    @vacancy_form = vacancy_form
  end
end
