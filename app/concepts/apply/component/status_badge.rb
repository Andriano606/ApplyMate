# frozen_string_literal: true

# Status pill linking to the apply card on the vacancy page (or to the new-apply modal when not applied).
# Live-updated by Apply::TurboHandler::StatusUpdate.
class Apply::Component::StatusBadge < ApplyMate::Component::Base
  LAZY = :lazy

  # Broadcasts (ApplicationController.renderer has no current_user) pass apply: and user: explicitly.
  def initialize(vacancy:, apply: LAZY, user: LAZY, **)
    @vacancy      = vacancy
    @apply_preset = apply
    @user_preset  = user
  end

  def before_render
    @user  = @user_preset == LAZY ? current_user : @user_preset
    @apply = @apply_preset == LAZY ? Apply.latest_for(vacancy: @vacancy, user: @user) : @apply_preset
  end

  private

  def link_options
    if @apply.nil?
      { data: { turbo_stream: true } }
    else
      { data: { turbo_frame: '_top' } }
    end
  end

  def path
    if @apply.nil?
      helpers.new_apply_path(vacancy_id: @vacancy.hashid)
    else
      helpers.vacancy_path(@vacancy, anchor: Apply::Component::VacancyApplyCard.anchor_id(@apply))
    end
  end
end
