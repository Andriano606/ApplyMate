# frozen_string_literal: true

class VacancyFormsController < ApplicationController
  def index
    endpoint VacancyForm::Operation::Index, VacancyForm::Component::Index
  end

  def new
    endpoint VacancyForm::Operation::New, VacancyForm::Component::NewModal
  end

  def create
    endpoint VacancyForm::Operation::Create, VacancyForm::Component::NewModal do |m|
      m.success do |result|
        VacancyForm::TurboHandler::Index.broadcast(result.model.vacancy_form)
        turbo_actions = [ turbo_stream.close_active_modal ]
        turbo_actions << turbo_stream.flash([ [ result.message_level, result.notice[:text] ] ])
        render turbo_stream: turbo_actions
      end
    end
  end
end
