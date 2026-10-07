# frozen_string_literal: true

class Apply::Component::NewModal < ApplyMate::Component::Base
  def initialize(apply:, **)
    @apply = apply
  end

  private

  # A previous apply may already have submitted: the user must confirm applying again (Create enforces it).
  def reapply_guarded?
    @apply.vacancy.present? && Apply.reapply_guarded(vacancy: @apply.vacancy, user: current_user).exists?
  end
end
