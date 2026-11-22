# frozen_string_literal: true

class Vacancy::Component::List < ApplyMate::Component::Base
  def initialize(vacancies:, hidden_vacancy_ids: [])
    @vacancies = vacancies
    @hidden_vacancy_ids = hidden_vacancy_ids
  end

  private

  def hidden?(vacancy)
    @hidden_vacancy_ids.include?(vacancy.id)
  end

  def paginate?
    @vacancies.respond_to?(:total_pages) && @vacancies.total_pages > 1
  end
end
