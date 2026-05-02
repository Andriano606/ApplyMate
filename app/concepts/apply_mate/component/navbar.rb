# frozen_string_literal: true

class ApplyMate::Component::Navbar < ApplyMate::Component::Base
  include ApplyMate::Component::Navbar::UserHelpers

  private

  def items
    @items ||= build_items.select(&:render?)
  end

  def items_by_section
    @items_by_section ||= items.group_by(&:section)
  end

  def build_items # rubocop:disable Metrics/MethodLength
    [
      #-- Logo --
      Item.new(label: 'ApplyMate', path: root_path, section: :logo),

      Item.new(label: I18n.t('navbar.add_new_source'), path: helpers.new_admin_source_path, section: :actions, render: current_user&.admin?, turbo: :stream),

      Item.new(label: I18n.t('navbar.my_profiles'), path: helpers.user_profiles_path, section: :user_menu, render: signed_in?, icon: :user),
      Item.new(label: I18n.t('navbar.ai_integrations'), path: helpers.ai_integrations_path, section: :user_menu, render: signed_in?, icon: :sparkles),
      Item.new(label: I18n.t('navbar.source_profiles'), path: helpers.source_profiles_path, section: :user_menu, render: signed_in?, icon: :lock_closed),
      Item.new(label: I18n.t('navbar.my_applies'), path: helpers.applies_path, section: :user_menu, render: signed_in?, icon: :clipboard_list),
      Item.new(label: I18n.t('navbar.stop_impersonating'), path: helpers.admin_impersonation_path, section: :user_menu, render: impersonating?, method: :delete, turbo: false, divider: true),
      Item.new(label: I18n.t('navbar.sign_out'),     path: logout_path,       section: :user_menu, render: signed_in? && !impersonating?, method: :delete, turbo: false, divider: true),

      #-- Guest --
      Item.new(label: I18n.t('navbar.sign_in'),        path: helpers.login_path, section: :guest,  render: !signed_in?, turbo: :stream)
    ]
  end
  def oauth_path        = helpers.google_oauth_path
  def logout_path       = '/logout'
end
