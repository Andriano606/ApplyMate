# frozen_string_literal: true

# Anyone can read feedback; only signed-in users post one, and only their own can be edited.
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
end
