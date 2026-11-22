# Vacancy Bank Architecture

ApplyMate is a vacancy bank: it keeps the list of live vacancies from several job boards (DOU, Djinni) up to date through a proxy pool, and lets users search, filter and hide them (Elasticsearch).

## Module Boundaries

These are enforced boundaries, not guidelines. Violating them causes cross-layer coupling between transport and domain logic.

| Module | Responsibility | Uses |
|--------|---------------|------|
| `ApplyMate::Client::AsyncHttp` | Default HTTP transport: GET/POST through an HTTP/SOCKS5 proxy, redirects, timeouts. Fiber-friendly | `async`, raw sockets |
| `ApplyMate::Client::ImpersonateHttp` | Drop-in for `AsyncHttp` that shells out to curl-impersonate (Chrome TLS fingerprint) for Cloudflare-protected sources | `Open3` |
| `ApplyMate::Client::Response` | Shared response struct: `body`, `headers`, `status`, `final_url` | — |
| `ApplyMate::Scraper::*` | Source-specific parsing: `fetch_listing(page:)`, optional `fetch_description(url)`. Never builds its own client | a client passed to the constructor |
| `Vacancy::Operation::SyncVacancies` | Drives the scrapers: proxy pool, fibers, pagination, upsert, stale-vacancy handling | scrapers, clients, `Proxy` |
| `Proxy::Operation::*` | Fetch candidate proxies, persist them, validate them against a source's `listing_url` | clients, `ProxySourceStat` |
| `Vacancy::Operation::{Index,Search,...}` | Read side: Elasticsearch search over `Vacancy` | `Vacancy` (ES mappings) |
| `Mcp::Tool::*` / `Mcp::Operation::*` | MCP server at `/mcp`: tools are adapters, each runs one operation that reuses the read side | `Vacancy::Operation::Search`, `HiddenVacancy::Operation::*` |

Details: `.ai/docs/scrapers.md`, `.ai/docs/sync_vacancies.md`, `.ai/docs/mcp.md`, `.ai/docs/proxy.md`, `.ai/docs/fetch_proxies.md`, `.ai/docs/async.md`.

## Rules

**The scraper class picks its client.**
`ApplyMate::Scraper::Base.http_client_class` defaults to `ApplyMate::Client::AsyncHttp`; a scraper overrides it (Dou → `ImpersonateHttp`). Everything that needs a client for a source asks the scraper class, never hardcodes one:

```ruby
# Vacancy::Operation::SyncVacancies — one client + scraper per proxied request
client  = scraper_class.http_client_class.new(proxy: proxy.url, request_timeout: HTTP_REQUEST_TIMEOUT, connect_timeout: HTTP_CONNECT_TIMEOUT)
scraper = scraper_class.new(source, client)
```

Every client class must therefore accept the `(proxy:, request_timeout:, connect_timeout:)` constructor.

**Scrapers only parse.**
A scraper receives `(source, client)`, makes the HTTP calls it needs through `@client` wrapped in `via_proxy`, and returns `ApplyMate::Operation::Struct`s. It does not touch the database, the proxy pool or Elasticsearch.

**Dead proxies are signalled, not swallowed.**
Transport failures, `502/503/504`, and blocked/empty pages raise `ApplyMate::Scraper::Base::DeadProxyError`; `SyncVacancies` drops that proxy from rotation and retries the page on another.

**Behaviour switches live in the scraper class API.**
`listing_url(source)`, `validation_url(source)`, `fetches_description?`, `burst_cooldown`, `http_client_class` are class methods on `Scraper::Base` with defaults; callers (sync, proxy validation, totals widget) call them instead of comparing scraper names.

## Adding a new job board

1. Create `app/concepts/apply_mate/scraper/my_site.rb` inheriting `ApplyMate::Scraper::Base`: constructor `(source, client)`, `fetch_listing(page:)`; override `listing_url`, `http_client_class`, `burst_cooldown`, and (`fetches_description?` + `fetch_description(url)`) only if needed.
2. Add `'ApplyMate::Scraper::MySite'` to `Source::SCRAPERS` in `app/models/source.rb` (it validates inclusion and feeds the admin source form select).
3. Create the `Source` row (admin UI: name, `base_url`, logo, scraper). Seeds for development live in `db/seeds/development/`.
4. Add a spec for the scraper (see `.ai/docs/rspec.md`) — `SyncVacancies` and `Proxy::Operation::Validate` pick the new source up through `Source.all`.
