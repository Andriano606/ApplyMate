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
    Mcp::Tool::GetMyFeedback,
    Mcp::Tool::ListFeedback,
    Mcp::Tool::SubmitFeedback,
    Mcp::Tool::ReplyToFeedback,
    Mcp::Tool::DeleteFeedback
  ].freeze

  INSTRUCTIONS = <<~TEXT
    ApplyMate is a vacancy bank: it keeps an up-to-date list of live job vacancies scraped from
    several job boards (list_sources). Use search_vacancies to find vacancies by keywords
    (boolean expressions with and/or/parentheses, Ukrainian operators і/або work too), by job
    board or via one of the user's saved filters (list_saved_filters), then get_vacancies to read
    the full descriptions. Closed vacancies disappear after the next sync, so ids can go stale.
    ApplyMate also has a public feedback page about the service itself: list_feedback reads it,
    submit_feedback publishes the user's rating (1–10) and comment — one per user, later calls
    replace it — get_my_feedback shows their review with the thread of admins' answers (new ones
    flagged), reply_to_feedback answers in a thread (admins may reply under any review) and
    delete_feedback removes the user's review (admins: any). New replies in threads the user takes
    part in are flagged `new: true`; list_feedback with unread_only lists just those threads.
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
