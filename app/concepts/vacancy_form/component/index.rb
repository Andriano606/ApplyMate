# frozen_string_literal: true

class VacancyForm::Component::Index < ApplyMate::Component::Base
  LAZY = :lazy

  def initialize(vacancy:, vacancy_forms:, user: LAZY, **)
    @vacancy       = vacancy
    @vacancy_forms = vacancy_forms
    @user_preset   = user
  end

  def before_render
    @page_user = @user_preset == LAZY ? current_user : @user_preset
  end

  private

  def page_user
    @page_user
  end

  def form_title(index)
    @vacancy_forms.size == 1 ? I18n.t('vacancy_form.index.title_single') : "#{I18n.t('vacancy_form.index.title_single')} #{index + 1}"
  end
end
