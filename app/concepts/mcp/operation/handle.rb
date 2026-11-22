# frozen_string_literal: true

# Serves one MCP request (result model: a Rack [status, headers, body] triple).
#
# Stateless Streamable HTTP with plain JSON responses: every POST carries a whole
# JSON-RPC exchange, so a fresh server + transport per request is all the state
# there is — nothing to share between Puma threads, no SSE stream to hold open.
# DNS-rebinding protection is off because it guards cookie-less local servers;
# this endpoint requires a bearer token a browser never attaches on its own, and
# Host is already checked by Rails' config.hosts.
class Mcp::Operation::Handle < ApplyMate::Operation::Base
  VERSION = '1.0.0'

  TOOLS = [
    Mcp::Tool::SearchVacancies,
    Mcp::Tool::GetVacancies,
    Mcp::Tool::ListSources,
    Mcp::Tool::ListSavedFilters,
    Mcp::Tool::SetVacancyHidden
  ].freeze

  INSTRUCTIONS = <<~TEXT
    ApplyMate is a vacancy bank: it keeps an up-to-date list of live job vacancies scraped from
    several job boards (list_sources). Use search_vacancies to find vacancies by keywords
    (boolean expressions with and/or/parentheses, Ukrainian operators і/або work too), by job
    board or via one of the user's saved filters (list_saved_filters), then get_vacancies to read
    the full descriptions. Closed vacancies disappear after the next sync, so ids can go stale.
    set_vacancy_hidden marks a vacancy as dismissed for the user; hidden ones are skipped by search.
  TEXT

  def perform!(request:, current_user:, **)
    authorize! :mcp, :access?

    server = MCP::Server.new(name: 'applymate', title: 'ApplyMate', version: VERSION,
                             instructions: INSTRUCTIONS, tools: TOOLS, capabilities: { tools: {} },
                             server_context: { current_user: })
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      enable_json_response: true,
      serve_subscriptions_listen: false,
      dns_rebinding_protection: false
    )
    server.transport = transport

    request.body.rewind # Rails may have read it while parsing params
    self.model = transport.handle_request(request)
  end
end
