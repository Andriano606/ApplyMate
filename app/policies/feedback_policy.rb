# frozen_string_literal: true

# Anyone can read feedback; only signed-in users post one, only their own can be edited,
# and it can be deleted by its author or an admin.
class FeedbackPolicy < ApplicationPolicy
  def index?
    true
  end

  def create?
    user.present?
  end

  def update?
    user.present? && record.user_id == user.id
  end

  # The author, or an admin moderating.
  def destroy?
    user.present? && (record.user_id == user.id || user.admin?)
  end
end
