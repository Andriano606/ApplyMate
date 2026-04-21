# frozen_string_literal: true

class Admin::User::Component::Index < ApplyMate::Component::Base
  available_for :admin

  def initialize(users:, **)
    @users = users
  end

  def header_opts
    {
      title: I18n.t('admin.user.index.title'),
      back_link: helpers.admin_root_path,
      back_text: I18n.t('admin.common.back_to_dashboard')
    }
  end

  private

  attr_reader :users
end
