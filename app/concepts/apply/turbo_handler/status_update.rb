# frozen_string_literal: true

class Apply::TurboHandler::StatusUpdate < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    view_context.turbo_stream_from([ user, vacancy ])
  end

  def self.frame_tag(vacancy, user, view_context, &block)
    view_context.turbo_frame_tag(frame_id(vacancy, user), &block)
  end

  def self.broadcast(apply)
    vacancy = apply.vacancy
    user = apply.user
    html = ApplicationController.renderer.render_to_string(
      Apply::Component::StatusBadge.new(vacancy: vacancy, apply: apply),
      layout: false,
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
    "apply_status_#{vacancy.hashid}_#{user.hashid}"
  end
end
