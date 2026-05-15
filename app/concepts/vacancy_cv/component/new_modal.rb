# frozen_string_literal: true

class VacancyCv::Component::NewModal < ApplyMate::Component::Base
  def initialize(vacancy:, vacancy_cv:, **)
    @vacancy    = vacancy
    @vacancy_cv = vacancy_cv
  end
end
