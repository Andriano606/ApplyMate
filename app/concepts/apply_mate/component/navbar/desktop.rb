# frozen_string_literal: true

class ApplyMate::Component::Navbar::Desktop < ApplyMate::Component::Base
  include ApplyMate::Component::Navbar::UserHelpers

  def initialize(items_by_section:)
    @items_by_section = items_by_section
    super()
  end

  private

  def logo_item       = @items_by_section.fetch(:logo, []).first
  def nav_items       = @items_by_section.fetch(:nav, [])
  def action_items    = @items_by_section.fetch(:actions, [])
  def user_menu_items = @items_by_section.fetch(:user_menu, [])
  def guest_items     = @items_by_section.fetch(:guest, [])

  def active?(item)
    helpers.request.path.start_with?(item.path)
  end

  COUNT_BADGE_CLASSES = 'absolute -right-2 -top-2 flex h-4 min-w-4 items-center justify-center rounded-full ' \
                        'bg-red-500 px-1 text-[10px] font-bold leading-none text-white ring-2 ring-white ' \
                        'dark:ring-gray-800'
  ACTION_BASE = 'inline-flex h-9 items-center gap-1.5 rounded-lg px-3 text-sm font-medium leading-none transition-colors'
  ACTION_VARIANTS = {
    primary: 'bg-indigo-600 text-white hover:bg-indigo-700',
    outline: 'text-gray-700 ring-1 ring-inset ring-gray-300 hover:bg-gray-50 ' \
             'dark:text-gray-200 dark:ring-gray-600 dark:hover:bg-gray-700',
    ghost: 'text-gray-600 hover:bg-gray-100 hover:text-gray-900 dark:text-gray-300 dark:hover:bg-gray-700'
  }.freeze
  ACTION_ACTIVE = 'bg-indigo-50 text-indigo-700 dark:bg-indigo-900/40 dark:text-indigo-300'

  def nav_link_classes(item)
    "#{ACTION_BASE} #{active?(item) ? ACTION_ACTIVE : ACTION_VARIANTS[:ghost]}"
  end

  def action_link_classes(item)
    variant = item.variant == :ghost && active?(item) ? ACTION_ACTIVE : ACTION_VARIANTS.fetch(item.variant)
    "#{ACTION_BASE} #{variant}"
  end
end
