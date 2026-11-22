# MCP server

ApplyMate exposes its vacancy bank to Claude (and any other MCP client) as a
[Model Context Protocol](https://modelcontextprotocol.io) server at `/mcp`, built on the
official `mcp` gem. Read this before adding or changing an MCP tool.

## Transport and auth

- **Streamable HTTP, stateless, JSON responses.** `POST /mcp` carries one JSON-RPC exchange and gets
  one JSON answer; there are no sessions and no SSE streams (`GET /mcp` answers 405). That is why
  `Mcp::Operation::Handle` builds a fresh `MCP::Server` + `StreamableHTTPTransport` per request —
  nothing is shared between Puma threads.
- **API token.** `Authorization: Bearer <token>` with a token from *Admin → API tokens*
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

Ids are hashids everywhere (`to_param`), never bare integers.

### How search composes

`search_vacancies` never builds Elasticsearch JSON itself: a saved filter becomes
`include_tags/include_ops/exclude_tags`, `query` becomes a `must_tags` entry (ANDed with the whole
filter expression — appending it as another tag would bind wrongly next to an `or`), `exclude` is
appended to `exclude_tags`, and `Vacancy::Operation::BuildSearchQuery` turns it all into one bool
query, adding `filter: terms source_id` and `must_not: terms vacancy_id` (hidden ids).
These keyword options of `Vacancy::Operation::Search` (`per_page`, `sort`, `must_tags`,
`source_ids`, `exclude_hidden`) are never read from request params — only trusted callers set them.

`source_id` is an Elasticsearch field added after the index existed. The ES initializer
`put_mapping`s new fields onto an existing index on boot (a failure is logged at error level — until
it succeeds the `sources` filter matches nothing), and every sync run re-imports each listed
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

Claude Code:

```bash
claude mcp add --transport http applymate https://staging.beapply.xyz/mcp \
  --header "Authorization: Bearer <api token>"
```

Any client that can send a static `Authorization` header works the same way. claude.ai custom
connectors need OAuth, which this endpoint does not implement.
