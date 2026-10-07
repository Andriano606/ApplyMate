# frozen_string_literal: true

# Non-link status pill of an apply (nil apply = "not applied"), with a spinner while the pipeline is in progress.
# The one owner of STATE_CONFIG: StatusBadge, ActionBox, FailureNotice's callers and VacancyApplyCard render this.
class Apply::Component::StatusPill < ApplyMate::Component::Base
  YELLOW = 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300'
  AMBER = 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300'
  GRAY = 'bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-300'

  STATE_CONFIG = {
    not_applied: { icon: :send, color: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300' },
    queued: { icon: :clock, color: YELLOW },
    running: { icon: :sparkles, color: YELLOW },
    waiting_capacity: { icon: :clock, color: YELLOW },
    needs_review: { icon: :eye, color: AMBER },
    needs_human: { icon: :user, color: AMBER },
    submit_unverified: { icon: :exclamation_triangle, color: AMBER },
    completed: { icon: :check_circle, color: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300' },
    failed: { icon: :x_circle, color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300' },
    unsupported: { icon: :x_circle, color: GRAY },
    cancelled: { icon: :x_mark, color: GRAY }
  }.freeze

  def initialize(apply:)
    @apply = apply
  end

  private

  def in_progress?
    @apply.present? && @apply.in_progress?
  end

  def config
    STATE_CONFIG.fetch(@apply.nil? ? :not_applied : @apply.state.to_sym)
  end

  def color_class
    config[:color]
  end

  def status_icon
    config[:icon]
  end

  # A running apply shows what it is doing; every other state shows the state itself.
  def label
    return I18n.t('apply.new.button') if @apply.nil?
    return I18n.t("apply.stage.#{@apply.stage}") if @apply.running? && @apply.stage.present?

    I18n.t("apply.state.#{@apply.state}")
  end
end
