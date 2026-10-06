# frozen_string_literal: true

# Single entry point for "a user's apply state for a vacancy changed". One [user, vacancy] stream carries
# every per-user apply view of that vacancy: the status badge (this handler's frame), the vacancy page
# action box (Apply::TurboHandler::ActionBox) and the applies panel (Apply::TurboHandler::VacancyIndex).
class Apply::TurboHandler::StatusUpdate < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    view_context.turbo_stream_from([ user, vacancy ])
  end

  def self.frame_tag(vacancy, user, view_context, &block)
    view_context.turbo_frame_tag(frame_id(vacancy, user), &block)
  end

  # A pipeline step changed one apply: badge, action box and only that apply's card. Re-rendering the whole
  # panel here would collapse the accordions / reset the tabs the user opened on the other cards every step.
  def self.broadcast(apply)
    latest = broadcast_summary(apply.vacancy, apply.user)
    Apply::TurboHandler::VacancyIndex.broadcast_card(apply, open: apply == latest)
  end

  # The set of applies changed (Apply::Operation::Create / Destroy): badge, action box and the whole panel.
  def self.refresh(vacancy, user)
    broadcast_summary(vacancy, user)
    Apply::TurboHandler::VacancyIndex.broadcast(vacancy, user)
  end

  # Returns the latest apply both views were rendered for.
  def self.broadcast_summary(vacancy, user)
    apply = Apply.latest_for(vacancy:, user:)
    html = ApplicationController.renderer.render_to_string(
      Apply::Component::StatusBadge.new(vacancy:, apply:, user:),
      layout: false,
    )

    Turbo::StreamsChannel.broadcast_action_to(
      [ user, vacancy ],
      action: :replace,
      target: frame_id(vacancy, user),
      html:
    )
    Apply::TurboHandler::ActionBox.broadcast(vacancy, user, apply)
    apply
  end

  private_class_method :broadcast_summary

  private

  def self.frame_id(vacancy, user)
    "apply_status_#{vacancy.hashid}_#{user.hashid}"
  end
end
