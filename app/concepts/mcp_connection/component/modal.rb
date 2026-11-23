# frozen_string_literal: true

# "Connect Claude (MCP)": one button copies the ready command (creating the
# personal token on first click, see mcp_connect_controller.ts), another one
# regenerates the token.
class McpConnection::Component::Modal < ApplyMate::Component::Base
  MODAL_ID = 'mcp_connection_modal'
  REGENERATE_PANEL_CLASSES = 'flex flex-col gap-3 rounded-lg border border-red-100 bg-red-50/60 p-3 ' \
                             'sm:flex-row sm:items-center sm:justify-between dark:border-red-900 dark:bg-red-900/20'

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
    'inline-flex shrink-0 items-center whitespace-nowrap justify-center rounded-lg border border-red-200 bg-white px-3 py-2 ' \
      'text-xs font-medium text-red-700 transition-colors hover:bg-red-50 ' \
      'dark:border-red-800 dark:bg-gray-800 dark:text-red-300 dark:hover:bg-red-900/30'
  end

  def token_status
    return I18n.t('mcp_connection.modal.no_token') unless api_token

    created = helpers.l(api_token.created_at, format: :short)
    used = if api_token.last_used_at
             I18n.t('mcp_connection.modal.used', time: helpers.l(api_token.last_used_at, format: :short))
    else
             I18n.t('mcp_connection.modal.never_used')
    end
    I18n.t('mcp_connection.modal.token_status', created:, used:)
  end
end
