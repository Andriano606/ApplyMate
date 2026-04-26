# frozen_string_literal: true

class Apply::TurboHandler::StatusUpdate < ApplyMate::TurboHandler::Base
  def self.stream_from(apply, view_context)
    view_context.turbo_stream_from(apply)
  end

  def self.frame_tag(apply, view_context, &block)
    view_context.turbo_frame_tag(frame_id(apply), &block)
  end

  def self.broadcast(apply)
    Turbo::StreamsChannel.broadcast_action_to(
      apply,
      action: :replace,
      target: frame_id(apply),
      html: ApplicationController.render(Apply::Component::StatusBadge.new(apply: apply), layout: false)
    )
  end

  private

  def self.frame_id(apply)
    "apply_status_#{apply.hashid}"
  end
end
