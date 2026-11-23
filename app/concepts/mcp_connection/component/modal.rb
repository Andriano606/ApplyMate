# frozen_string_literal: true

# "Connect Claude (MCP)": one button copies the ready command (creating the
# personal token on first click, see mcp_connect_controller.ts), another one
# regenerates the token.
class McpConnection::Component::Modal < ApplyMate::Component::Base
  MODAL_ID = 'mcp_connection_modal'

  def initialize(api_token:, **)
    @api_token = api_token
  end

  private

  attr_reader :api_token

  def title
    I18n.t('mcp_connection.modal.title')
  end

  def command
    api_token ? Mcp::Component::ConnectCommand.text(url: helpers.mcp_url, token: api_token.token) : ''
  end

  def regenerate_button_classes
    "#{ApplyMate::Component::Button::VARIANTS[:outline]} #{ApplyMate::Component::Button::SIZES[:sm]} mt-2"
  end

  def token_status
    return I18n.t('mcp_connection.modal.no_token') unless api_token

    created = helpers.l(api_token.created_at, format: :short)
    used = api_token.last_used_at ? helpers.l(api_token.last_used_at, format: :short) : I18n.t('mcp_connection.modal.never_used')
    I18n.t('mcp_connection.modal.token_status', created:, used:)
  end
end
