# frozen_string_literal: true

class Apply::TurboHandler::StatusUpdate < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, view_context)
    view_context.turbo_stream_from(vacancy)
  end

  def self.frame_tag(vacancy, view_context, &block)
    view_context.turbo_frame_tag(frame_id(vacancy), &block)
  end

  def self.broadcast(vacancy)
    html = ApplicationController.renderer.render_to_string(
      Apply::Component::StatusBadge.new(vacancy: vacancy),
      layout: false,
    )

    Turbo::StreamsChannel.broadcast_action_to(
      vacancy,
      action: :replace,
      target: frame_id(vacancy),
      html:
    )
  end

  private

  def self.frame_id(vacancy)
    "apply_status_#{vacancy.hashid}"
  end
end
