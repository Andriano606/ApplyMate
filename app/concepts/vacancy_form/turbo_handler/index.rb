# frozen_string_literal: true

class VacancyForm::TurboHandler::Index < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy, user, view_context)
    view_context.turbo_stream_from([ user, vacancy, :vacancy_forms ])
  end

  def self.frame_tag(vacancy, view_context, src: nil, &block)
    view_context.turbo_frame_tag(frame_id(vacancy), src:, &block)
  end

  def self.broadcast(vacancy_form)
    user          = vacancy_form.user
    vacancy       = vacancy_form.vacancy
    vacancy_forms = VacancyForm.joins(:user_profile)
                               .where(user_profiles: { user: }, vacancy:)
                               .order(:created_at)
    html = ApplicationController.renderer.render_to_string(
      VacancyForm::Component::Index.new(vacancy:, vacancy_forms:, user:),
      layout: false
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ user, vacancy, :vacancy_forms ],
      action: :replace,
      target: frame_id(vacancy),
      html:
    )
  end

  private

  def self.frame_id(vacancy)
    "vacancy_forms_#{vacancy.hashid}"
  end
end
