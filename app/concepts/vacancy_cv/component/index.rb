# frozen_string_literal: true

class VacancyCv::Component::Index < ApplyMate::Component::Base
  LAZY = :lazy

  # cvs: VacancyCv and Apply records, newest first (VacancyCv::Operation::Index).
  def initialize(vacancy:, cvs:, user: LAZY, **)
    @vacancy     = vacancy
    @cvs         = cvs
    @user_preset = user
  end

  def before_render
    @page_user = @user_preset == LAZY ? current_user : @user_preset
  end

  private

  def page_user
    @page_user
  end

  # Manual CVs still generating get a per-item CvReady subscription; apply CVs refresh per row
  # on the list stream (VacancyCv::TurboHandler::Index.broadcast_row).
  def pending_vacancy_cvs
    @cvs.select { |record| record.is_a?(VacancyCv) && !record.cv.attached? }
  end
end
