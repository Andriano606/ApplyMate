# frozen_string_literal: true

class VacancyCv::TurboHandler::CvReady < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy_cv, user, view_context)
    view_context.turbo_stream_from([ user, vacancy_cv ])
  end

  def self.frame_tag(vacancy_cv, view_context, &block)
    view_context.turbo_frame_tag(frame_id(vacancy_cv), class: 'block', &block)
  end

  def self.broadcast(vacancy_cv)
    user    = vacancy_cv.user
    vacancy = vacancy_cv.vacancy
    ids     = vacancy.vacancy_cvs.order(:created_at).pluck(:id)
    index   = ids.index(vacancy_cv.id).to_i
    title   = ids.size == 1 ? I18n.t('apply.show.fields.cv') : "#{I18n.t('apply.show.fields.cv')} #{index + 1}"

    html = ApplicationController.renderer.render_to_string(
      VacancyCv::Component::CvContent.new(vacancy_cv:, title:),
      layout: false
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ user, vacancy_cv ],
      action: :replace,
      target: frame_id(vacancy_cv),
      html:
    )
  end

  private

  def self.frame_id(vacancy_cv)
    "vacancy_cv_content_#{vacancy_cv.id}_#{vacancy_cv.user.hashid}"
  end
end
