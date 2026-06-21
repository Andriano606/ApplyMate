# frozen_string_literal: true

class Admin::ApiToken::Component::Index < ApplyMate::Component::Base
  available_for :admin

  def initialize(api_tokens:, **)
    @api_tokens = api_tokens
  end

  def header_opts
    {
      title: I18n.t('admin.api_token.index.title'),
      back_link: helpers.admin_root_path,
      back_text: I18n.t('admin.common.back_to_dashboard')
    }
  end
end
