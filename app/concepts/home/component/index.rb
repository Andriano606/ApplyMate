# frozen_string_literal: true

class Home::Component::Index < ApplyMate::Component::Base
  def initialize(vacancies:, total_vacancies:, **)
    @vacancies = vacancies
    @total_vacancies = total_vacancies
  end
end
