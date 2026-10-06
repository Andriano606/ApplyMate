# frozen_string_literal: true

class VacancyAppliesController < ApplicationController
  def index
    endpoint Apply::Operation::VacancyIndex, Apply::Component::VacancyIndex
  end
end
