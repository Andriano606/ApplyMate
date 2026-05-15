# frozen_string_literal: true

class VacancyCvsController < ApplicationController
  def index
    endpoint VacancyCv::Operation::Index, VacancyCv::Component::Index
  end

  def new
    endpoint VacancyCv::Operation::New, VacancyCv::Component::NewModal
  end

  def create
    endpoint VacancyCv::Operation::Create, VacancyCv::Component::NewModal do |m|
      m.success do |result|
        VacancyCv::TurboHandler::Index.broadcast(result.model.vacancy_cv)
        turbo_actions = [ turbo_stream.close_active_modal ]
        turbo_actions << turbo_stream.flash([ [ result.message_level, result.notice[:text] ] ])
        render turbo_stream: turbo_actions
      end
    end
  end
end
