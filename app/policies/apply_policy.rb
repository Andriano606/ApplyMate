# frozen_string_literal: true

class ApplyPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    user.present?
  end

  def new?
    user.present?
  end

  def create?
    user.present?
  end

  def destroy?
    user.present?
  end

  def resume?
    owner?
  end

  def cancel?
    owner?
  end

  def approve_review?
    owner?
  end

  def mark_outcome?
    owner?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(user:)
    end
  end

  private

  def owner?
    user.present? && record.user_id == user.id
  end
end
