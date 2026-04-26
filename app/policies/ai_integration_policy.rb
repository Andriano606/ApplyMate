# frozen_string_literal: true

class AiIntegrationPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def new?
    create?
  end

  def create?
    user.present?
  end

  def update?
    user.present? && record.user == user
  end

  def edit?
    update?
  end

  def destroy?
    update?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(user:)
    end
  end
end
