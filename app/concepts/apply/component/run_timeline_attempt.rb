# frozen_string_literal: true

# The step rows of one attempt inside RunTimeline. Stacked on phones, a three-column grid from sm up.
class Apply::Component::RunTimelineAttempt < ApplyMate::Component::Base
  STATE_ICONS = {
    'succeeded' => { icon: :check_circle, color: 'text-green-600 dark:text-green-400' },
    'failed' => { icon: :x_circle, color: 'text-red-600 dark:text-red-400' },
    'skipped' => { icon: :x_mark, color: 'text-gray-400 dark:text-gray-500' }
  }.freeze

  def initialize(steps:, user:)
    @steps = steps
    @user  = user
  end

  private

  def duration_label(step)
    seconds = step.duration
    return if seconds.nil?
    return I18n.t('apply.timeline.duration_seconds', count: seconds.round) if seconds < 60

    helpers.distance_of_time_in_words(seconds)
  end

  def error_title(step)
    I18n.t("apply.failure.#{step.error_code}") if step.failed? && step.error_code.present?
  end

  def error_detail(step)
    step.error_detail.presence if step.failed? && @user&.admin?
  end

  # [[filename, path]] of the failure / pre-submit evidence (masked screenshots, redacted HTML) of the step.
  def artifact_links(step)
    step.ordered_artifacts.each.with_index(1).map do |attachment, position|
      [ attachment.filename.to_s, helpers.artifact_path('apply_step', step, position) ]
    end
  end

  def icon_config(step)
    STATE_ICONS[step.state]
  end
end
