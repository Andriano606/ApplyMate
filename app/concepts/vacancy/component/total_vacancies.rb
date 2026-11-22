# frozen_string_literal: true

class Vacancy::Component::TotalVacancies < ApplyMate::Component::Base
  private

  def total_vacancies
    @total_vacancies ||= begin
      counts = Vacancy::Operation::CountBySource.call.model
      Source.all.map { |source| ApplyMate::Operation::Struct.new(source:, count: counts[source.id].to_i) }
    end
  end

  def total_count
    total_vacancies.sum(&:count)
  end
end
