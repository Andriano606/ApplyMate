# frozen_string_literal: true

class VacancyCv::Component::CvContent < ApplyMate::Component::Base
  def initialize(vacancy_cv:, title:)
    @vacancy_cv = vacancy_cv
    @vacancy    = vacancy_cv.vacancy
    @title      = title
  end
end
