# frozen_string_literal: true

class Home::Operation::Index < ApplyMate::Operation::Base
  def perform!(params:, current_user:)
    skip_authorize

    saved_filter = apply_default_filter(params, current_user)

    vacancies = run_operation(Vacancy::Operation::Search, { params:, current_user: }).model
    self.model = ApplyMate::Operation::Struct.new(
      vacancies:,
      include_tags: params[:include_tags],
      include_ops: params[:include_ops],
      exclude_tags: params[:exclude_tags],
      saved_filter:,
      # Guests get a short "what is this" banner naming the job boards (tiny table).
      guest_source_names: (Source.order(:name).pluck(:name) if current_user.nil?)
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
