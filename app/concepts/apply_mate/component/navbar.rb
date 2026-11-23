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

      #-- Right side --
      Item.new(label: I18n.t('navbar.feedbacks'), section: :actions, variant: :ghost, prefetch: false,
               path: unread_replies.positive? ? helpers.feedbacks_path(unread: 1) : helpers.feedbacks_path,
               badge: (I18n.t('navbar.feedbacks_unread', count: unread_replies) if unread_replies.positive?),
               badge_count: unread_replies),
      Item.new(label: I18n.t('navbar.connect_mcp'), path: helpers.mcp_connection_path, section: :actions, variant: :outline,
               icon: :sparkles, render: signed_in?, turbo: :stream),

      Item.new(label: I18n.t('navbar.stop_impersonating'), path: helpers.admin_impersonation_path, section: :user_menu, render: impersonating?, method: :delete, turbo: false, divider: true),
      Item.new(label: I18n.t('navbar.sign_out'),     path: logout_path,       section: :user_menu, render: signed_in? && !impersonating?, method: :delete, turbo: false, divider: true),

      #-- Guest --
      Item.new(label: I18n.t('navbar.sign_in'),        path: helpers.login_path, section: :guest,  render: !signed_in?, turbo: :stream)
    ]
  end
  # New replies in the user's feedback threads. Prefetch is off on that link: a
  # hover would load the page and mark the replies read.
  def unread_replies
    @unread_replies ||= signed_in? ? current_user.unread_feedback_reply_count : 0
  end

  def oauth_path        = helpers.google_oauth_path
  def logout_path       = '/logout'
end
