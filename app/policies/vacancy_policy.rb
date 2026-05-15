# frozen_string_literal: true

class VacancyPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    true
  end
end
