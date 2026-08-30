# frozen_string_literal: true

class HomeController < ApplicationController
  def index
    endpoint Home::Operation::Index, Vacancy::Component::Index
  end
end
