# frozen_string_literal: true

class Vacancy::Component::Show < ApplyMate::Component::Base
  def initialize(vacancy:, apply: nil, expanded: false, **)
    @vacancy = vacancy
    @apply = apply
    @expanded = expanded
  end

  private

  def header_opts
    { title: @vacancy.title, back_link: helpers.vacancies_path, back_text: I18n.t('vacancy.show.back') }
  end

  def expand_url
    helpers.vacancy_path(@vacancy, expanded: true)
  end

  def collapse_url
    helpers.vacancy_path(@vacancy)
  end
end
