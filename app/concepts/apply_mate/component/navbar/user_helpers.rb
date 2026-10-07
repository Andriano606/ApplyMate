# frozen_string_literal: true

module ApplyMate::Component::Navbar::UserHelpers
  extend ActiveSupport::Concern

  ATTENTION_DOT_CLASSES = 'absolute -right-1 -top-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-red-600 ' \
                          'px-1 text-xs font-semibold leading-none text-white'

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

  # Applies needing attention, read off the menu items' badges (Navbar#build_items already resolved it once).
  def menu_attention_count
    @items_by_section.fetch(:user_menu, []).sum { |item| item.badge.to_i }
  end

  def user_email
    current_user.email
  end
end
