# frozen_string_literal: true

# Non-link status pill of an apply (nil apply = "not applied"), with a spinner while the pipeline runs.
# The one owner of STATUS_CONFIG: StatusBadge, ActionBox and VacancyApplyCard all render this.
class Apply::Component::StatusPill < ApplyMate::Component::Base
  STATUS_CONFIG = {
    not_applied: {
      icon: :send,
      color: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300'
    },
    generating_cv: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :sparkles
    },
    sending_cv: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :send
    },
    completed: {
      color: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300',
      icon: :check_circle
    },
    failed_generating_cv: {
      color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
      icon: :x_circle
    },
    failed_sending_cv: {
      color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
      icon: :x_circle
    },
    fetching_details: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :magnifying_glass
    },
    failed_fetching_details: {
      color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
      icon: :x_circle
    },
    checking_applyble: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :magnifying_glass
    },
    failed_checking_applyble: {
      color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
      icon: :x_circle
    },
    fetching_apply_type: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :magnifying_glass
    },
    failed_fetching_apply_type: {
      color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
      icon: :x_circle
    },
    fetching_form: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :magnifying_glass
    },
    failed_fetching_form: {
      color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
      icon: :x_circle
    },
    filling_form: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :sparkles
    },
    failed_filling_form: {
      color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
      icon: :x_circle
    }
  }.freeze

  FALLBACK_CONFIG = { color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300', icon: :clock }.freeze

  def initialize(apply:)
    @apply = apply
  end

  private

  def in_progress?
    @apply.present? && @apply.in_progress?
  end

  def config
    return STATUS_CONFIG[:not_applied] if @apply.nil?

    STATUS_CONFIG[@apply.status&.to_sym] || FALLBACK_CONFIG
  end

  def color_class
    config[:color]
  end

  def status_icon
    config[:icon]
  end

  # A freshly created apply has no status until Apply::Job::Apply starts its first step.
  def label
    return I18n.t('apply.new.button') if @apply.nil?
    return I18n.t('apply.status.queued') if @apply.status.nil?

    I18n.t("apply.status.#{@apply.status}")
  end
end
