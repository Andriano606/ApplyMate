# frozen_string_literal: true

class VacancyQuestion::TurboHandler::Index < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    view_context.turbo_stream_from([ user, vacancy, :vacancy_questions ])
  end

  def self.frame_tag(vacancy, view_context, src: nil, &block)
    view_context.turbo_frame_tag(frame_id(vacancy), src:, &block)
  end

  # Renders exactly what VacancyQuestionsController#index renders, through the same operation.
  # Callers: VacancyQuestionsController#create (new question), Apply::Operation::FetchInternalForm and
  # Apply::Operation::Ai::FetchExternalForm (new form → new suggestions), Apply::Operation::Destroy.
  def self.broadcast(vacancy, user)
    result = VacancyQuestion::Operation::Index.call(params: { vacancy_id: vacancy.id }, current_user: user)
    html = ApplicationController.renderer.render_to_string(
      VacancyQuestion::Component::Index.new(**result.model.to_h, user:),
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
