# frozen_string_literal: true

# Serves one MCP request (result model: a Rack [status, headers, body] triple).
#
# Stateless Streamable HTTP with plain JSON responses: every POST carries a whole
# JSON-RPC exchange, so a fresh server + transport per request is all the state
# there is — nothing to share between Puma threads, no SSE stream to hold open.
# DNS-rebinding protection is off because it guards cookie-less local servers;
# this endpoint requires a bearer token a browser never attaches on its own, and
# Host is already checked by Rails' config.hosts.
#
# Every JSON-RPC message is logged as an `mcp_request` event (who, which tool,
# how it ended) for the Grafana dashboard «Використання MCP» — see
# .ai/docs/observability.md.
class Mcp::Operation::Handle < ApplyMate::Operation::Base
  include ApplyMate::Logging

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
                             server_context: { current_user: },
                             configuration: MCP::Configuration.new(around_request: usage_logger(current_user, request)))
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

  private

  # Wraps each JSON-RPC message the server handles. `data` is the gem's
  # instrumentation hash: `method`, and for tools/call `tool_name` plus `error`
  # when the call was refused before reaching the tool.
  def usage_logger(user, request)
    client = client_name(request)
    lambda do |data, &handler|
      log_usage(data, user:, client:) { handler.call }
    end
  end

  def log_usage(data, user:, client:)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error_type = 'internal_error' # stays when the handler raises
    response = yield
    error_type = ('tool_error' if response.is_a?(Hash) && response[:isError])
    response
  ensure
    error_type = data[:error]&.to_s || error_type # the gem's reason (invalid_params, invalid_schema, …) wins
    log(event: 'mcp_request', level: error_type ? :warn : :info,
        rpc: data[:method], tool: data[:tool_name], user: user.hashid, user_name: user.name,
        client: (client if data[:method] == MCP::Methods::INITIALIZE),
        result: error_type ? 'failed' : 'ok', error_type:,
        duration_s: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
  end

  # The MCP client (claude-ai, claude-code, …) introduces itself only in
  # `initialize`, so that is the one message it is logged with.
  def client_name(request)
    request.body.rewind
    messages = Array.wrap(JSON.parse(request.body.read))
    messages.filter_map { |message| message.dig('params', 'clientInfo', 'name') if message.is_a?(Hash) }.first
  rescue JSON::ParserError, TypeError # not JSON, or `params` / `clientInfo` is not an object
    nil
  ensure
    request.body.rewind
  end
end
