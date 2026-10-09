# frozen_string_literal: true

# The single owner of the exit buttons per state (design §11.1), rendered by ActionBox and VacancyApplyCard.
# Every button is a link that Turbo turns into a POST; the responses carry only a flash, the card/box refresh
# through the StatusUpdate broadcast the operation triggers.
class Apply::Component::Actions < ApplyMate::Component::Base
  POST = { turbo_method: :post, turbo_stream: true }.freeze

  def initialize(apply:)
    @apply = apply
  end

  def render?
    buttons.any?
  end

  private

  def buttons
    @buttons ||= case @apply.state
    when 'needs_human', 'unsupported' then human_buttons
    when 'failed' then failed_buttons
    when 'submit_unverified' then unverified_buttons
    when 'completed', 'cancelled' then [ reapply_button ]
    else []
    end
  end

  def human_buttons
    [ open_link_button, (resume_button('fixed_retry') if @apply.resumable?), manual_button, cancel_button ].compact
  end

  def failed_buttons
    [ (resume_button('retry') if @apply.resumable?), manual_button, cancel_button ].compact
  end

  def unverified_buttons
    [
      { key: 'sent', variant: :primary, url: helpers.mark_outcome_apply_path(@apply, outcome: 'sent'), data: POST },
      { key: 'not_sent', variant: :outline,
        url: helpers.mark_outcome_apply_path(@apply, outcome: 'not_sent', confirm: 1),
        data: POST.merge(turbo_confirm: I18n.t('apply.mark_outcome.not_sent_warning')) }
    ]
  end

  def open_link_button
    url = @apply.external_url.presence || @apply.vacancy.external_url.presence || @apply.vacancy.url
    return if url.blank?

    { key: 'open_link', variant: :primary, url:, icon: :external_link, target: '_blank', rel: 'noopener noreferrer' }
  end

  def resume_button(key)
    { key:, variant: :outline, url: helpers.resume_apply_path(@apply), icon: :refresh, data: POST }
  end

  def manual_button
    { key: 'applied_manually', variant: :outline, url: helpers.mark_outcome_apply_path(@apply, outcome: 'manual'),
      icon: :check, data: POST.merge(turbo_confirm: I18n.t('apply.actions.applied_manually_confirm')) }
  end

  def cancel_button
    { key: 'cancel', variant: :outline, url: helpers.cancel_apply_path(@apply),
      data: POST.merge(turbo_confirm: I18n.t('apply.actions.cancel_confirm')) }
  end

  def reapply_button
    { key: 'reapply', variant: :outline, icon: :send,
      url: helpers.new_apply_path(vacancy_id: @apply.vacancy.hashid), data: { turbo_stream: true } }
  end
end
