# MCP server

ApplyMate exposes its vacancy bank to Claude (and any other MCP client) as a
[Model Context Protocol](https://modelcontextprotocol.io) server at `/mcp`, built on the
official `mcp` gem. Read this before adding or changing an MCP tool.

## Transport and auth

- **Streamable HTTP, stateless, JSON responses.** `POST /mcp` carries one JSON-RPC exchange and gets
  one JSON answer; there are no sessions and no SSE streams (`GET /mcp` answers 405). That is why
  `Mcp::Operation::Handle` builds a fresh `MCP::Server` + `StreamableHTTPTransport` per request —
  nothing is shared between Puma threads.
- **API token.** `Authorization: Bearer <token>` — the user's own token from the
  *Connect Claude (MCP)* modal (see below) or one an admin issued in *Admin → API tokens*
  (`ApiToken`, looked up by `UserHandling#user_from_token`, which also stamps `last_used_at`).
  No token / unknown token → `401` with `WWW-Authenticate: Bearer` (`McpPolicy#access?`).
  Every tool runs as the token's user, so saved filters and hidden vacancies are that user's.
- DNS-rebinding protection of the gem is off: it protects cookie-authenticated local servers,
  this endpoint only accepts a bearer token, and `Host` is checked by Rails `config.hosts`.

## Layout

| Piece | Role |
|-------|------|
| `McpController#handle` | Calls `Mcp::Operation::Handle`, copies the Rack triple into the response |
| `Mcp::Operation::Handle` | `authorize! :mcp, :access?`, builds server (tools, instructions, `server_context: { current_user: }`) |
| `Mcp::Tool::Base` | `run(operation, server_context, params) { |model| payload }` — runs ONE operation as the token user, verifies it authorized, turns a failed result into an MCP tool error (`isError: true`) and a payload into text JSON + `structuredContent` |
| `Mcp::Tool::*` | Schema + description + serialization only. **No business logic** — that goes in an operation |
| `Mcp::Operation::*` | The logic behind each tool (resolve saved filter / sources, batch lookups, hide/restore) |
| `Vacancy::Serializer::{Summary,Detail}` | Search hit (with 300-char snippet) / full record (`include_html:` adds `description_html`) |

## Tools

| Tool | Operation | Notes |
|------|-----------|-------|
| `search_vacancies` | `Mcp::Operation::SearchVacancies` → `Vacancy::Operation::Search` | `query` (boolean expression, same parser as the search bar), `exclude`, `sources` (names or ids), `saved_filter_id`, `include_hidden` (default false), `sort` (`newest`/`relevance`), `page`, `per_page` (≤ 100, default 20) |
| `get_vacancies` | `Mcp::Operation::GetVacancies` | up to 20 ids, order kept, unknown ids in `missing_ids` |
| `list_sources` | `Mcp::Operation::ListSources` | counts come from `Vacancy::Operation::CountBySource` (cached 5 min, expired by the sync) |
| `list_saved_filters` | `Mcp::Operation::ListSavedFilters` | only the token user's filters |
| `set_vacancy_hidden` | `Mcp::Operation::SetVacancyHidden` | wraps `HiddenVacancy::Operation::{Create,Destroy}`; idempotent |
| `get_my_feedback` | `Mcp::Operation::GetMyFeedback` | the token user's feedback or `null` |
| `submit_feedback` | `Mcp::Operation::SubmitFeedback` | `rating` (1–10) + `comment`; creates the user's single feedback, later calls replace it (`created: false`); wraps `Feedback::Operation::{Create,Update}` with `posted_via: 'mcp'`. See `.ai/docs/feedback.md` |

Ids are hashids everywhere (`to_param`), never bare integers.

### How search composes

`search_vacancies` never builds Elasticsearch JSON itself: a saved filter becomes
`include_tags/include_ops/exclude_tags`, `query` becomes a `must_tags` entry (ANDed with the whole
filter expression — appending it as another tag would bind wrongly next to an `or`), `exclude` is
appended to `exclude_tags`, and `Vacancy::Operation::BuildSearchQuery` turns it all into one bool
query, adding `filter: terms source_id` and `must_not: terms vacancy_id` (hidden ids).
These keyword options of `Vacancy::Operation::Search` (`per_page`, `sort`, `must_tags`,
`source_ids`, `exclude_hidden`) are never read from request params — only trusted callers set them.

`source_id` is an Elasticsearch field added after the index existed. On boot the ES initializer
reads the index mapping and `put_mapping`s only when a field is missing, capped at 5s
(`MAPPING_UPDATE_TIMEOUT`) so a stuck Elasticsearch master can never hold the web container past
kamal-proxy's 30s health check (a failure is logged at error level — until it succeeds the
`sources` filter matches nothing), and every sync run re-imports each listed
vacancy, so the field fills itself by the next daily sync. Until then `sources` returns only
vacancies indexed since the deploy; to fill it at once, after deploying:
`bin/kamal app exec -d staging "bin/rails runner 'Vacancy.import'"`.

Pagination: `total_entries` is the real match count, but Elasticsearch serves at most
`Vacancy::MAX_RESULT_WINDOW` (50 000) hits deep, so `total_pages` / `next_page` stop at
`Vacancy::Operation::Search.last_reachable_page(per_page)` — following `next_page` always ends.

## Adding a tool

1. Write the operation (`app/concepts/mcp/operation/…`) — it must `authorize!` (or `skip_authorize`)
   and report user-facing failures with `add_error` + `raise ActiveRecord::RecordInvalid`; messages
   live under `mcp.errors.*` in both locales.
2. Write `Mcp::Tool::<Name> < Mcp::Tool::Base`: `tool_name` (snake_case), `title`, a description
   written for the model (what it returns, when to use it), `input_schema` with
   `additionalProperties: false`, `annotations` (`READ_ONLY` for reads), and
   `def self.call(server_context:, …, **)` that only calls `run`.
3. Register it in `Mcp::Operation::Handle::TOOLS`.
4. Cover it in `spec/requests/mcp_spec.rb` through `POST /mcp` (the real path, not the class).

## Connecting Claude

**Users** connect from the user menu → *Підключити Claude (MCP)* (`McpConnectionsController`,
`resource :mcp_connection`). The modal (`McpConnection::Component::Modal`, fixed id
`mcp_connection_modal`) is re-rendered by every action as a Turbo Stream:

| Action | Operation | What it does |
|--------|-----------|--------------|
| `GET /mcp_connection` | `McpConnection::Operation::Show` | shows the modal; **never** creates a token (prefetch-safe) |
| `POST /mcp_connection` | `McpConnection::Operation::Create` | get-or-create the user's personal token |
| `PATCH /mcp_connection` | `McpConnection::Operation::Update` | regenerate it (old value stops working, `last_used_at` reset) |

The personal token is the `ApiToken` with `personal: true` (at most one per user — unique partial
index `index_api_tokens_on_user_id_personal`; `create_or_find_by!` makes double clicks safe).
Admin-issued tokens are `personal: false` and are never touched by the modal.

*Copy command* is one click even without a token: `mcp_connect_controller.ts` POSTs to
`/mcp_connection`, reads the command out of the returned stream and hands it to the clipboard as a
promise (`ClipboardItem`, so Safari/Firefox still treat it as part of the click), then renders the
stream. With a token it just copies `data-mcp-connect-command-value`.

The admin page **Admin → MCP server** (`/admin/mcp`, `Admin::Mcp::Operation::Show`, admin-only via
`McpPolicy#show?`) shows the endpoint URL, the tool list (read from `Mcp::Operation::Handle::TOOLS`)
and, for each of the current admin's own API tokens, the ready-to-run command with a copy-to-clipboard
button (`clipboard` Stimulus controller). Without a token it shows the command with an `<API_TOKEN>`
placeholder and a link to create one. Both places build the command with
`Mcp::Component::ConnectCommand` (`.text(url:, token:)` / renders the `<code>`):

```bash
claude mcp add --transport http --scope user applymate https://staging.beapply.xyz/mcp \
  --header "Authorization: Bearer <api token>"
```

Any client that can send a static `Authorization` header works the same way. claude.ai custom
connectors need OAuth, which this endpoint does not implement.
