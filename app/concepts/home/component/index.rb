# frozen_string_literal: true

class Home::Component::Index < ApplyMate::Component::Base
  def initialize(vacancies:, total_vacancies:, query: nil, exclude: nil, **)
    @vacancies = vacancies
    @total_vacancies = total_vacancies
    @query = query
    @exclude = exclude
  end
end
