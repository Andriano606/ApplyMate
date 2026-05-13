# frozen_string_literal: true

class ProxyPolicy < ApplicationPolicy
  def index?
    user&.admin?
  end

  def show?
    user&.admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.all if user&.admin?
    end
  end
end
