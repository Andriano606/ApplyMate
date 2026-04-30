# frozen_string_literal: true

class Home::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize

    if current_user
      params[:include_tags] = current_user.include_tags
      params[:include_ops] = current_user.include_ops
      params[:exclude_tags] = current_user.exclude_tags
    end

    result = run_operation Vacancy::Operation::Search, { params:, current_user: }
    vacancies = result.model
    applies_by_vacancy = if current_user
      current_user.applies.where(vacancy_id: vacancies.map(&:id)).index_by(&:vacancy_id)
    else
      {}
    end
    self.model = ApplyMate::Operation::Struct.new(
      vacancies:,
      applies_by_vacancy:,
      include_tags: params[:include_tags],
      include_ops: params[:include_ops],
      exclude_tags: params[:exclude_tags],
      total_vacancies: Source.all.map do |source|
        ApplyMate::Operation::Struct.new(
          count: source.vacancies.count,
          source: source
        )
      end
    )
  end
end
