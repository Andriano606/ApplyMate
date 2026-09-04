# frozen_string_literal: true

class Home::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize

    saved_filter = apply_default_filter(params, current_user)

    result = run_operation Vacancy::Operation::Search, { params:, current_user: }
    vacancies = result.model
    run_operation(SavedFilter::Operation::RecordView,
                  { saved_filter:, vacancies:,
                    include_tags: params[:include_tags],
                    include_ops:  params[:include_ops],
                    exclude_tags: params[:exclude_tags] })
    applies_by_vacancy = if current_user
      current_user.applies.where(vacancy_id: vacancies.map(&:id)).index_by(&:vacancy_id)
    else
      {}
    end
    self.model = ApplyMate::Operation::Struct.new(
      vacancies:,
      applies_by_vacancy:,
      hidden_vacancy_ids: HiddenVacancy.vacancy_ids_for(user: current_user, vacancies:),
      include_tags: params[:include_tags],
      include_ops: params[:include_ops],
      exclude_tags: params[:exclude_tags],
      saved_filter:
    )
  end

  private

  # Opening the home page with no explicit search applies the user's default
  # preset; returns the preset that is now on screen, if any.
  def apply_default_filter(params, current_user)
    return if params[:include_tags].present? || params[:exclude_tags].present?

    default_filter = current_user&.default_saved_filter
    return unless default_filter

    params[:include_tags] = default_filter.include_tags
    params[:include_ops]  = default_filter.include_ops
    params[:exclude_tags] = default_filter.exclude_tags
    default_filter
  end
end
