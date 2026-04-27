# frozen_string_literal: true

class Apply::Component::StatusBadge < ApplyMate::Component::Base
  STATUS_CONFIG = {
    pending: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :clock
    },
    generating_cv: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :sparkles
    },
    cv_generated: {
      color: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300',
      icon: :check
    },
    sending_cv: {
      color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300',
      icon: :send
    },
    completed: {
      color: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300',
      icon: :check_circle
    },
    failed_cv_generation: {
      color: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
      icon: :x_circle
    },
    failed_cv_sending: {
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

  def initialize(apply:)
    @apply = apply
  end

  private

  def config
    STATUS_CONFIG[@apply.status.to_sym] || STATUS_CONFIG[:pending]
  end

  def color_class
    config[:color]
  end

  def status_icon
    config[:icon]
  end

  def label
    I18n.t("apply.status.#{@apply.status}")
  end
end
