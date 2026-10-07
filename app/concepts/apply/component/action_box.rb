# frozen_string_literal: true

# Apply-state box of the vacancy page sidebar (signed-in users only). Live-updated through
# Apply::TurboHandler::ActionBox by every Apply::TurboHandler::StatusUpdate broadcast/refresh.
class Apply::Component::ActionBox < ApplyMate::Component::Base
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

  # :none, :in_progress, :completed, :attention or :cancelled
  def state
    return :none if @apply.nil?
    return :completed if @apply.completed?
    return :cancelled if @apply.cancelled?
    return :attention if @apply.needs_attention?

    :in_progress
  end

  def new_apply_path
    helpers.new_apply_path(vacancy_id: @vacancy.hashid)
  end
end
