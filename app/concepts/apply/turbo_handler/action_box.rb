# frozen_string_literal: true

# Apply-state box in the vacancy page sidebar. Shares the [user, vacancy] stream of
# Apply::TurboHandler::StatusUpdate, whose broadcast/refresh is the only caller of broadcast.
class Apply::TurboHandler::ActionBox < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    Apply::TurboHandler::StatusUpdate.stream_from(vacancy, user, view_context)
  end

  def self.frame_tag(vacancy, user, view_context, &block)
    view_context.turbo_frame_tag(frame_id(vacancy, user), &block)
  end

  def self.broadcast(vacancy, user, apply)
    html = ApplicationController.renderer.render_to_string(
      Apply::Component::ActionBox.new(vacancy:, apply:, user:),
      layout: false
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ user, vacancy ],
      action: :replace,
      target: frame_id(vacancy, user),
      html:
    )
  end

  private

  def self.frame_id(vacancy, user)
    "apply_action_box_#{vacancy.hashid}_#{user.hashid}"
  end
end
