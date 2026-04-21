# frozen_string_literal: true

class ApplyMate::Component::Navbar::Mobile < ApplyMate::Component::Base
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

  def menu_items
    @menu_items ||= nav_items + action_items + user_menu_items + guest_items
  end
end
