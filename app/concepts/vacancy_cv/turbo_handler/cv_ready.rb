# frozen_string_literal: true

# Per-CV frame of VacancyCv::Component::CvContent. frame_tag accepts any CV record (VacancyCv or Apply) and
# doubles as the "#cv_<record>" anchor; only manual VacancyCvs are broadcast here (VacancyCv::Job::Create) —
# apply CVs refresh through VacancyCv::TurboHandler::Index.broadcast_row.
class VacancyCv::TurboHandler::CvReady < ApplyMate::TurboHandler::Base
  def self.stream_from(vacancy_cv, user, view_context)
    view_context.turbo_stream_from([ user, vacancy_cv ])
  end

  def self.frame_tag(record, view_context, **options, &block)
    view_context.turbo_frame_tag(frame_id(record), **options, &block)
  end

  def self.broadcast(vacancy_cv)
    html = ApplicationController.renderer.render_to_string(
      VacancyCv::Component::CvContent.new(record: vacancy_cv),
      layout: false
    )
    Turbo::StreamsChannel.broadcast_action_to(
      [ vacancy_cv.user, vacancy_cv ],
      action: :replace,
      target: frame_id(vacancy_cv),
      html:
    )
  end

  # "cv_vacancy_cv_<hashid>" / "cv_apply_<hashid>": distinct per model, never a bare integer id.
  def self.frame_id(record)
    "cv_#{record.model_name.singular}_#{record.hashid}"
  end
end
