# frozen_string_literal: true

class VacancyCv::TurboHandler::Index < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    view_context.turbo_stream_from([ user, vacancy, :vacancy_cvs ])
  end

  def self.frame_tag(vacancy, view_context, src: nil, &block)
    view_context.turbo_frame_tag(frame_id(vacancy), src:, &block)
  end

  # Callers: VacancyCvsController#create, Apply::Operation::Destroy, Apply::Operation::Ai::GeneratePdfCv (its
  # placeholder appears). Renders exactly what VacancyCvsController#index renders, through the same operation.
  # A row is only ever added through here: an insert relative to a sibling row would be dropped whenever that
  # sibling is not rendered yet (e.g. two applies starting at once), and nothing would repair the list.
  def self.broadcast(vacancy, user)
    broadcast_list(index_model(vacancy, user), user)
  end

  # A listed CV row changed in place or disappeared (Apply::Operation::Ai::GeneratePdfCv cleanup: the
  # placeholder becomes the CV or goes away). Touches only that row's own frame — rows are sorted by the
  # immutable created_at, so a row never moves — and the CV accordions/tabs open on the other rows survive.
  # Falls back to the whole list when the last row is gone (the empty state swaps in).
  def self.broadcast_row(record)
    vacancy, user = record.vacancy, record.user
    model  = index_model(vacancy, user)
    return broadcast_list(model, user) if model.cvs.empty?

    stream = [ user, vacancy, :vacancy_cvs ]
    target = VacancyCv::TurboHandler::CvReady.frame_id(record)
    return Turbo::StreamsChannel.broadcast_remove_to(stream, target:) unless model.cvs.include?(record)

    html = ApplicationController.renderer.render_to_string(VacancyCv::Component::CvContent.new(record:), layout: false)
    Turbo::StreamsChannel.broadcast_action_to(stream, action: :replace, target:, html:)
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
