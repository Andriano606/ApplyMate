# frozen_string_literal: true

class SavedFilterPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def create?
    user.present?
  end

  def update?
    user.present? && record.user_id == user.id
  end

  def destroy?
    user.present? && record.user_id == user.id
  end
end
