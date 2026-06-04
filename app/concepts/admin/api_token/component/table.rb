# frozen_string_literal: true

class Admin::ApiToken::Component::Table < ApplyMate::Component::Base
  available_for :admin

  def initialize(api_tokens:, **)
    @api_tokens = api_tokens
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @api_tokens, empty_message: I18n.t('admin.api_token.index.empty'))

    table.add_column(header: I18n.t('admin.api_token.index.table.user')) do |api_token|
      helpers.content_tag(:span, api_token.user.email, class: 'text-sm')
    end

    table.add_column(header: I18n.t('admin.api_token.index.table.name')) do |api_token|
      api_token.name.presence || '—'
    end

    table.add_column(header: I18n.t('admin.api_token.index.table.token')) do |api_token|
      helpers.content_tag(:span, api_token.token, class: 'font-mono text-xs break-all')
    end

    table.add_column(header: I18n.t('admin.api_token.index.table.last_used_at')) do |api_token|
      api_token.last_used_at ? helpers.l(api_token.last_used_at, format: :short) : '—'
    end

    table.add_column(header: I18n.t('admin.api_token.index.table.created_at')) do |api_token|
      helpers.l(api_token.created_at, format: :short)
    end

    table.add_column(header: I18n.t('admin.api_token.index.table.actions'), type: :actions) do |api_token|
      delete_table_button(link: helpers.admin_api_token_path(api_token),
                          confirm: I18n.t('admin.api_token.index.revoke_confirm'))
    end

    render table
  end
end
