# frozen_string_literal: true

class VacancyQuestionsController < ApplicationController
  def index
    endpoint VacancyQuestion::Operation::Index, VacancyQuestion::Component::Index
  end

  def new
    endpoint VacancyQuestion::Operation::New, VacancyQuestion::Component::NewModal
  end

  def create
    endpoint VacancyQuestion::Operation::Create, VacancyQuestion::Component::NewModal do |m|
      m.success do |result|
        VacancyQuestion::TurboHandler::Index.broadcast(result.model.vacancy_question)
        turbo_actions = [ turbo_stream.close_active_modal ]
        turbo_actions << turbo_stream.flash([ [ result.message_level, result.notice[:text] ] ])
        render turbo_stream: turbo_actions
      end
    end
  end
end
