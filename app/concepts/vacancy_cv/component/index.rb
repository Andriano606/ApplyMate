# frozen_string_literal: true

class VacancyCv::Component::Index < ApplyMate::Component::Base
  LAZY = :lazy

  def initialize(vacancy:, vacancy_cvs:, user: LAZY, **)
    @vacancy     = vacancy
    @vacancy_cvs = vacancy_cvs
    @user_preset = user
  end

  def before_render
    @page_user = @user_preset == LAZY ? current_user : @user_preset
  end

  private

  def page_user
    @page_user
  end

  def cv_title(index)
    @vacancy_cvs.size == 1 ? I18n.t('apply.show.fields.cv') : "#{I18n.t('apply.show.fields.cv')} #{index + 1}"
  end
end
