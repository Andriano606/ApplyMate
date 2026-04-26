# frozen_string_literal: true

class Vacancy::Component::Index < ApplyMate::Component::Base
  def initialize(vacancies:, applies_by_vacancy: {})
    @vacancies = vacancies
    @applies_by_vacancy = applies_by_vacancy
  end

  private

  def paginate?
    @vacancies.respond_to?(:total_pages) && @vacancies.total_pages > 1
  end
end
