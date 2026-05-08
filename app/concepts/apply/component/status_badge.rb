# frozen_string_literal: true

class Apply::Component::StatusBadge < ApplyMate::Component::Base
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

  LAZY = :lazy

  def initialize(vacancy:, apply: LAZY, **)
    @vacancy = vacancy
    @apply_preset = apply
  end

  def before_render
    @apply = (@apply_preset == LAZY) ? @vacancy.applies.where(user: current_user).last : @apply_preset
  end

  private

  def path
    if @apply.nil?
      helpers.new_apply_path(vacancy_id: @vacancy.hashid)
    else
      helpers.apply_path(@apply)
    end
  end

  def turbo_stream
    @apply.nil? ? true : false
  end

  def turbo
    @apply.nil? ? true : false
  end

  def config
    if @apply.nil?
      STATUS_CONFIG[:not_applied]
    else
      STATUS_CONFIG[@apply.status&.to_sym] || { color: 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-300', icon: :clock }
    end
  end

  def color_class
    config[:color]
  end

  def status_icon
    config[:icon]
  end

  def label
    return I18n.t('apply.new.button') if @apply.nil?

    I18n.t("apply.status.#{@apply.status}", default: '')
  end

  def frame_user
    @apply.nil? ? current_user : @apply.user
  end
end
