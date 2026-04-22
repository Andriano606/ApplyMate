# frozen_string_literal: true

class Vacancy::Component::TotalVacancies < ApplyMate::Component::Base
  def initialize(total_vacancies:)
    @total_vacancies = total_vacancies
  end

  private

  def total_count
    @total_vacancies.sum(&:count)
  end
end
