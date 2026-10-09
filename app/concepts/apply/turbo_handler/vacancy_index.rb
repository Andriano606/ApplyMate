# frozen_string_literal: true

# "My applies" panel on the vacancy page (lazy frame, src: vacancy_applies_path). Shares the
# [user, vacancy] stream of Apply::TurboHandler::StatusUpdate: its refresh (applies added/removed) calls
# broadcast, its broadcast (one apply's status changed) calls broadcast_card.
class Apply::TurboHandler::VacancyIndex < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    Apply::TurboHandler::StatusUpdate.stream_from(vacancy, user, view_context)
  end

  def self.frame_tag(vacancy, user, view_context, src: nil, &block)
    view_context.turbo_frame_tag(frame_id(vacancy, user), src:, &block)
  end

  # Renders exactly what VacancyAppliesController#index renders, through the same operation.
  def self.broadcast(vacancy, user)
    result = Apply::Operation::VacancyIndex.call(params: { vacancy_id: vacancy.id }, current_user: user)
    html = ApplicationController.renderer.render_to_string(
      Apply::Component::VacancyIndex.new(**result.model.to_h, user:),
      layout: false
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ user, vacancy ],
      action: :replace,
      target: frame_id(vacancy, user),
      html:
    )
  end

  # Replaces only the "apply_<hashid>" card, so accordion/tab state on the other cards survives.
  # open: mirrors Apply::Component::VacancyIndex, which opens the newest card.
  def self.broadcast_card(apply, open:)
    html = ApplicationController.renderer.render_to_string(
      Apply::Component::VacancyApplyCard.new(apply:, open:, user: apply.user),
      layout: false
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ apply.user, apply.vacancy ],
      action: :replace,
      target: Apply::Component::VacancyApplyCard.anchor_id(apply),
      html:
    )
  end

  private

  def self.frame_id(vacancy, user)
    "vacancy_applies_#{vacancy.hashid}_#{user.hashid}"
  end
end
