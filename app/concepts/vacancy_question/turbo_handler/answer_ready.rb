# frozen_string_literal: true

class VacancyQuestion::TurboHandler::AnswerReady < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy_question, user, view_context)
    view_context.turbo_stream_from([ user, vacancy_question ])
  end

  def self.frame_tag(vacancy_question, view_context, &block)
    view_context.turbo_frame_tag(frame_id(vacancy_question), &block)
  end

  def self.broadcast(vacancy_question)
    user = vacancy_question.user

    html = ApplicationController.renderer.render_to_string(
      VacancyQuestion::Component::AnswerContent.new(vacancy_question:),
      layout: false
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ user, vacancy_question ],
      action: :replace,
      target: frame_id(vacancy_question),
      html:
    )
  end

  private

  def self.frame_id(vacancy_question)
    "vacancy_question_content_#{vacancy_question.id}_#{vacancy_question.user.hashid}"
  end
end
