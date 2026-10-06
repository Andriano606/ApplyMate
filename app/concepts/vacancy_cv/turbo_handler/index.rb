# frozen_string_literal: true

class VacancyCv::TurboHandler::Index < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    view_context.turbo_stream_from([ user, vacancy, :vacancy_cvs ])
  end

  def self.frame_tag(vacancy, view_context, src: nil, &block)
    view_context.turbo_frame_tag(frame_id(vacancy), src:, &block)
  end

  # Callers: VacancyCvsController#create, Apply::Operation::Destroy, broadcast_row.
  # Renders exactly what VacancyCvsController#index renders, through the same operation.
  def self.broadcast(vacancy, user)
    broadcast_list(index_model(vacancy, user), user)
  end

  # One CV row appeared, changed or disappeared (Apply::Operation::Ai::GeneratePdfCv: placeholder, then the
  # CV or nothing). Touches only that row — remove, then re-insert at its sorted position — so the CV
  # accordions/tabs the user has open on the other rows survive. Falls back to the whole list when the row
  # is the only one, or the last one is gone (the empty state swaps in or out).
  def self.broadcast_row(record)
    vacancy, user = record.vacancy, record.user
    model  = index_model(vacancy, user)
    cvs    = model.cvs
    index  = cvs.index(record)
    stream = [ user, vacancy, :vacancy_cvs ]
    return broadcast_list(model, user) if cvs.empty? || (index && cvs.one?)

    Turbo::StreamsChannel.broadcast_remove_to(stream, target: VacancyCv::TurboHandler::CvReady.frame_id(record))
    return if index.nil?

    # Newest first: insert before the next (older) row, or after the previous one when this row is the oldest.
    action, neighbour = index < cvs.size - 1 ? [ :before, cvs[index + 1] ] : [ :after, cvs[index - 1] ]
    html = ApplicationController.renderer.render_to_string(VacancyCv::Component::CvContent.new(record:), layout: false)
    Turbo::StreamsChannel.broadcast_action_to(
      stream, action:, target: VacancyCv::TurboHandler::CvReady.frame_id(neighbour), html:
    )
  end

  def self.index_model(vacancy, user)
    VacancyCv::Operation::Index.call(params: { vacancy_id: vacancy.id }, current_user: user).model
  end

  def self.broadcast_list(model, user)
    html = ApplicationController.renderer.render_to_string(
      VacancyCv::Component::Index.new(**model.to_h, user:),
      layout: false
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ user, model.vacancy, :vacancy_cvs ],
      action: :replace,
      target: frame_id(model.vacancy),
      html:
    )
  end

  private_class_method :index_model, :broadcast_list

  private

  def self.frame_id(vacancy)
    "vacancy_cvs_#{vacancy.hashid}"
  end
end
