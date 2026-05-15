# frozen_string_literal: true

class Vacancy::Component::Show < ApplyMate::Component::Base
  def initialize(vacancy:, **)
    @vacancy = vacancy
  end

  private

  def header_opts
    { title: @vacancy.title, back_link: helpers.root_path, back_text: I18n.t('vacancy.show.back') }
  end
end
