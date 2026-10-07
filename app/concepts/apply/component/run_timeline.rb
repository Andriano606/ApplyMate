# frozen_string_literal: true

# Step history of an apply: one row per ApplyStep, grouped by attempt (newest attempt first; older attempts sit
# inside a collapsed accordion). No artifacts yet (phase 3a).
class Apply::Component::RunTimeline < ApplyMate::Component::Base
  LAZY = :lazy

  # Broadcasts pass user: explicitly (admins see the redacted error detail).
  def initialize(apply:, user: LAZY)
    @apply       = apply
    @user_preset = user
  end

  def before_render
    @user = @user_preset == LAZY ? current_user : @user_preset
  end

  private

  # [[attempt, steps], ...] newest attempt first; steps are the preloaded association (VacancyIndex includes it).
  def attempts
    @attempts ||= @apply.apply_steps.sort_by { |step| [ step.attempt, step.position ] }
                        .group_by(&:attempt).sort_by { |attempt, _| -attempt }
  end
end
