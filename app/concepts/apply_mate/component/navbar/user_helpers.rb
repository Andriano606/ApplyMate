# frozen_string_literal: true

module ApplyMate::Component::Navbar::UserHelpers
  extend ActiveSupport::Concern

  private

  def user_display_name
    return current_user.name if name_parts.size < 2

    "#{name_parts.first} #{name_parts.last[0]}."
  end

  def user_initials
    return '?' if name_parts.empty?

    name_parts.map { |p| p[0] }.first(2).join.upcase
  end

  def name_parts
    @name_parts ||= current_user.name.to_s.split
  end

  def user_avatar?
    current_user.avatar.attached?
  end

  def user_email
    current_user.email
  end
end
