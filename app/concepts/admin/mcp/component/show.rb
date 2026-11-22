# frozen_string_literal: true

class Admin::Mcp::Component::Show < ApplyMate::Component::Base
  available_for :admin

  SERVER_NAME = 'applymate'
  TOKEN_PLACEHOLDER = '<API_TOKEN>'

  def initialize(api_tokens:, tools:, **)
    @api_tokens = api_tokens
    @tools = tools
  end

  def header_opts
    {
      title: I18n.t('admin.mcp.show.title'),
      back_link: helpers.admin_root_path,
      back_text: I18n.t('admin.common.back_to_dashboard')
    }
  end

  def endpoint_url
    helpers.mcp_url
  end

  # One line, so the clipboard controller's textContent is exactly the command.
  def connect_command(token)
    "claude mcp add --transport http --scope user #{SERVER_NAME} #{endpoint_url} " \
      "--header \"Authorization: Bearer #{token}\""
  end

  def token_label(api_token)
    api_token.name.presence || I18n.t('admin.mcp.show.unnamed_token', created_at: helpers.l(api_token.created_at, format: :short))
  end

  # First paragraph of the tool description — the rest is syntax help for the model.
  def tool_summary(tool)
    tool.description_value.to_s.split(/\n\s*\n/).first.to_s.squish
  end
end
