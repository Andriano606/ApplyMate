# frozen_string_literal: true

# The `claude mcp add …` command that connects Claude Code to /mcp with a token.
# One implementation for the user's modal and the admin MCP page.
class Mcp::Component::ConnectCommand < ApplyMate::Component::Base
  SERVER_NAME = 'applymate'
  TOKEN_PLACEHOLDER = '<API_TOKEN>'

  def self.text(url:, token: nil)
    "claude mcp add --transport http --scope user #{SERVER_NAME} #{url} " \
      "--header \"Authorization: Bearer #{token || TOKEN_PLACEHOLDER}\""
  end

  def initialize(token: nil, **html_options)
    @token = token
    @html_options = html_options
  end

  def call
    helpers.content_tag(:code, self.class.text(url: helpers.mcp_url, token: @token),
                        class: 'text-green-400 text-xs select-all whitespace-pre', **@html_options)
  end
end
