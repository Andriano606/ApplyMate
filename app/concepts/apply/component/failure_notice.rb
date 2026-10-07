# frozen_string_literal: true

# Why an apply stopped, in the user's words (apply.failure.<code> + apply.failure_hint.<code>); admins also see the
# redacted technical detail. Renders nothing while the apply is in progress or has no failure.
class Apply::Component::FailureNotice < ApplyMate::Component::Base
  LAZY = :lazy
  APPLY_YOURSELF_STATES = %w[needs_human unsupported].freeze

  # Broadcasts (ApplicationController.renderer has no current_user) pass user: explicitly.
  def initialize(apply:, user: LAZY)
    @apply       = apply
    @user_preset = user
  end

  def before_render
    @user = @user_preset == LAZY ? current_user : @user_preset
  end

  def render?
    @apply.failure.present? && !@apply.in_progress? && @apply.failure_code.present?
  end

  private

  def code
    @apply.failure_code
  end

  def title
    return I18n.t('apply.failure_notice.apply_yourself_title') if APPLY_YOURSELF_STATES.include?(@apply.state)

    I18n.t("apply.failure.#{code}")
  end

  # Under the "apply yourself" heading the specific reason moves into the hint.
  def reason
    return unless APPLY_YOURSELF_STATES.include?(@apply.state) && code != 'manual_apply_required'

    I18n.t("apply.failure.#{code}")
  end

  def hint
    I18n.t("apply.failure_hint.#{code}")
  end

  # ExpireWaiting's 48 h reminder for a needs_human / needs_review wait: when the wait will be closed.
  def reminder
    expires_at = @apply.wait_expires_at
    return unless @apply.reminded? && expires_at

    I18n.t('apply.failure_notice.reminder', date: I18n.l(expires_at, format: :short))
  end

  def after_claim?
    @apply.failure_info[:after_claim] == true
  end

  def detail
    return unless @user&.admin?

    @apply.failure_info[:detail].presence
  end
end
