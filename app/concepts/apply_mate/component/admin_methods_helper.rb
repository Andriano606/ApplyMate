# frozen_string_literal: true

module ApplyMate::Component::AdminMethodsHelper
  extend ActiveSupport::Concern

  class_methods do
    def available_for(*roles)
      @available_for_roles = roles
    end

    def available_for_roles
      @available_for_roles || []
    end
  end

  def render?
    roles = self.class.available_for_roles
    return true if roles.empty?

    roles.all? { |role| user_has_role?(role) }
  end

  private

  def user_has_role?(role)
    case role
    when :admin
      current_user&.admin?
    when :dev
      Rails.env.development?
    else
      false
    end
  end
end
