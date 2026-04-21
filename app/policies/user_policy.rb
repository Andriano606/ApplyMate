# frozen_string_literal: true

class UserPolicy < ApplicationPolicy
  def index?
    user&.admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.all if user&.admin?
    end
  end
end
