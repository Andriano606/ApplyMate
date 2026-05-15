# frozen_string_literal: true

class VacancyCvPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def new?
    user.present?
  end

  def create?
    user.present?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:user_profile).where(user_profiles: { user: })
    end
  end
end
