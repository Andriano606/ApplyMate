# frozen_string_literal: true

class VacancyQuestion::Component::Index < ApplyMate::Component::Base
  LAZY = :lazy

  def initialize(vacancy:, vacancy_questions:, user: LAZY, **)
    @vacancy           = vacancy
    @vacancy_questions = vacancy_questions
    @user_preset       = user
  end

  def before_render
    @page_user = @user_preset == LAZY ? current_user : @user_preset
  end

  private

  def page_user
    @page_user
  end
end
