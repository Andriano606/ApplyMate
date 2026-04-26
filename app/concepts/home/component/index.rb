# frozen_string_literal: true

class Home::Component::Index < ApplyMate::Component::Base
  def initialize(vacancies:, total_vacancies:, applies_by_vacancy: {}, query: nil, exclude: nil, **)
    @vacancies = vacancies
    @total_vacancies = total_vacancies
    @applies_by_vacancy = applies_by_vacancy
    @query = query
    @exclude = exclude
  end
end
