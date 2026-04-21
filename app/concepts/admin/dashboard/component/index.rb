# frozen_string_literal: true

class Admin::Dashboard::Component::Index < ApplyMate::Component::Base
  available_for :admin

  def initialize(**)
  end

  def header_opts
    {
      title: I18n.t('admin.dashboard.index.title'),
      back_link: helpers.root_path,
      back_text: I18n.t('admin.dashboard.index.back_to_site')
    }
  end

  def dashboard_card(path:, icon_bg:, title:, description:, turbo: true, &block)
    render(Admin::Dashboard::Component::Card.new(path:, icon_bg:, title:, description:, turbo:), &block)
  end
end
