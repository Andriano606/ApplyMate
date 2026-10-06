# frozen_string_literal: true

# "My applies" panel of the vacancy page: lazy frame (src: vacancy_applies_path), live-updated through
# Apply::TurboHandler::VacancyIndex. The page subscribes once via Apply::TurboHandler::StatusUpdate.stream_from.
class Apply::Component::VacancyIndex < ApplyMate::Component::Base
  LAZY = :lazy

  # applies: newest first (Apply::Operation::VacancyIndex). Broadcasts pass user: explicitly.
  def initialize(vacancy:, applies:, user: LAZY, **)
    @vacancy     = vacancy
    @applies     = applies
    @user_preset = user
  end

  def before_render
    @user = @user_preset == LAZY ? current_user : @user_preset
  end

  private

  def new_apply_path
    helpers.new_apply_path(vacancy_id: @vacancy.hashid)
  end
end
