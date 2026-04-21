# frozen_string_literal: true

class Admin::Source::Component::Index < ApplyMate::Component::Base
  available_for :admin

  def initialize(sources:, **)
    @sources = sources
  end

  def header_opts
    {
      title: I18n.t('admin.source.index.title'),
      back_link: helpers.admin_root_path,
      back_text: I18n.t('admin.common.back_to_dashboard')
    }
  end
end
