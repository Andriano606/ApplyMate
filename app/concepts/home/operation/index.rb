# frozen_string_literal: true

class Home::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize
    result = run_operation Vacancy::Operation::Index, { params:, current_user: }
    vacancies = result.model
    applies_by_vacancy = if current_user
      current_user.applies.where(vacancy_id: vacancies.map(&:id)).index_by(&:vacancy_id)
    else
      {}
    end
    self.model = ApplyMate::Operation::Struct.new(
      vacancies:,
      applies_by_vacancy:,
      query: params[:query],
      exclude: params[:exclude],
      total_vacancies: Source.all.map do |source|
        ApplyMate::Operation::Struct.new(
          count: source.vacancies.count,
          source: source
        )
      end
    )
  end
end
