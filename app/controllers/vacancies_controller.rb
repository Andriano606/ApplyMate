# frozen_string_literal: true

class VacanciesController < ApplicationController
  def index
    endpoint Vacancy::Operation::Index, Vacancy::Component::Index
  end

  def show
    endpoint Vacancy::Operation::Show, Vacancy::Component::Show
  end
end
