class Vacancy::Component::List < ApplyMate::Component::Base
  def initialize(vacancies:)
    @vacancies = vacancies
  end

  private

  def paginate?
    @vacancies.respond_to?(:total_pages) && @vacancies.total_pages > 1
  end
end
