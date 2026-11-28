# frozen_string_literal: true

class ProxyMateSettingPolicy < ApplicationPolicy
  def show?
    user&.admin?
  end

  def update?
    user&.admin?
  end
end
