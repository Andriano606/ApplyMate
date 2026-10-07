# frozen_string_literal: true

# The current user's applies for one vacancy (vacancy page "My applies" panel).
# Also called by Apply::TurboHandler::VacancyIndex.broadcast so live updates render the same data.
class Apply::Operation::VacancyIndex < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    vacancy = Vacancy.find(params[:vacancy_id])
    authorize! Apply.new, :index?
    # Rides index_applies_on_vacancy_id (a vacancy has a handful of applies), filtered by the user scope.
    applies = policy_scope(Apply).where(vacancy:)
                                 .includes(:user_profile, :ai_integration, :source_profile, :apply_steps)
                                 .with_attached_cv
                                 .with_attached_screenshot
                                 .order(created_at: :desc)

    self.model = ApplyMate::Operation::Struct.new(vacancy:, applies:)
  end
end
