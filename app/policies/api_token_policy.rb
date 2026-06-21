# frozen_string_literal: true

class ApiTokenPolicy < ApplicationPolicy
  def index?
    user&.admin?
  end

  def new?
    user&.admin?
  end

  def create?
    user&.admin?
  end

  def destroy?
    user&.admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.all if user&.admin?
    end
  end
end
