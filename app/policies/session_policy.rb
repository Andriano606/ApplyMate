# frozen_string_literal: true

class SessionPolicy < ApplicationPolicy
  def oauth_callback?
    true
  end

  def destroy?
    true
  end
end
