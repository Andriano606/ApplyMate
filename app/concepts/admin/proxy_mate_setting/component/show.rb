# frozen_string_literal: true

class Admin::ProxyMateSetting::Component::Show < ApplyMate::Component::Base
  available_for :admin

  def initialize(proxy_mate_setting:, status: nil, **)
    @setting = proxy_mate_setting
    @status = status
  end

  def header_opts
    {
      title: I18n.t('admin.proxy_mate_setting.show.title'),
      back_link: helpers.admin_root_path,
      back_text: I18n.t('admin.common.back_to_dashboard')
    }
  end

  # A just-saved URL wins, the ENV one is only the prefill while nothing is saved.
  def url_value
    @setting.url.presence || @setting.effective_url
  end

  def key_hint
    if @setting.api_key_preview
      I18n.t('admin.proxy_mate_setting.show.key_saved', preview: @setting.api_key_preview)
    else
      I18n.t('admin.proxy_mate_setting.show.key_missing')
    end
  end
end
