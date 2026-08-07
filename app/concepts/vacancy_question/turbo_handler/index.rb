# frozen_string_literal: true

class VacancyQuestion::TurboHandler::Index < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    view_context.turbo_stream_from([ user, vacancy, :vacancy_questions ])
  end

  def self.frame_tag(vacancy, view_context, src: nil, &block)
    view_context.turbo_frame_tag(frame_id(vacancy), src:, &block)
  end

  def self.broadcast(vacancy_question)
    user              = vacancy_question.user
    vacancy           = vacancy_question.vacancy
    vacancy_questions = VacancyQuestion.joins(:user_profile)
                                       .where(user_profiles: { user: }, vacancy:)
                                       .order(:created_at)
    html = ApplicationController.renderer.render_to_string(
      VacancyQuestion::Component::Index.new(vacancy:, vacancy_questions:, user:),
      layout: false
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ user, vacancy, :vacancy_questions ],
      action: :replace,
      target: frame_id(vacancy),
      html:
    )
  end

  private

  def self.frame_id(vacancy)
    "vacancy_questions_#{vacancy.hashid}"
  end
end
