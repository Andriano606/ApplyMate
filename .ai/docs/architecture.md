# Vacancy Bank Architecture

ApplyMate is a vacancy bank: it keeps the list of live vacancies from several job boards (DOU, Djinni) up to date through free proxies it takes from the separate **ProxyMate** service (which collects them, checks each one on each job site and obtains Cloudflare tokens), and lets users search and filter them (Elasticsearch).

## Module Boundaries

These are enforced boundaries, not guidelines. Violating them causes cross-layer coupling between transport and domain logic.

| Module | Responsibility | Uses |
|--------|---------------|------|
| `ApplyMate::Client::ImpersonateHttp` | The HTTP transport of every scraper: one curl-impersonate subprocess per GET/POST (`--impersonate chrome146`, or the target of a ProxyMate Cloudflare clearance) through an http / SOCKS4(a) / SOCKS5(h) proxy, `-L` redirects, timeouts; `Response` (`body`, `headers`, `status`, `final_url`). At most `MAX_PROCESSES` subprocesses at once per process | `Open3` |
| `ApplyMate::Client::ProxyMate` | JSON client of the ProxyMate API: proxy batches per site and session (`Batch` of `Proxy` / `Clearance`), sites, meta (curl-impersonate release/targets). Reports nothing back. Config: saved `ProxyMateSetting` (admin page `/admin/proxy_mate`), else ENV `PROXY_MATE_URL` / `PROXY_MATE_API_KEY` | `Net::HTTP` |
| `ApplyMate::Scraper::*` | Source-specific parsing: `fetch_listing(page:)`, optional `fetch_description(url)`. Never builds its own client | a client passed to the constructor |
| `Vacancy::Operation::SyncVacancies` | Drives the scrapers: in-memory proxy pool fed by ProxyMate (one session per run and source, per-proxy use limit per round, rounds when ProxyMate runs dry), fibers, pagination, upsert, stale-vacancy handling | scrapers, clients, `ApplyMate::Client::ProxyMate` |
| `Vacancy::Operation::{Index,Search,...}` | Read side: Elasticsearch search over `Vacancy` | `Vacancy` (ES mappings) |
| `Mcp::Tool::*` / `Mcp::Operation::*` | MCP server at `/mcp`: tools are adapters, each runs one operation that reuses the read side | `Vacancy::Operation::Search`, `Feedback::Operation::*` |

Details: `.ai/docs/scrapers.md`, `.ai/docs/sync_vacancies.md`, `.ai/docs/mcp.md`, `.ai/docs/async.md`.

ApplyMate stores no proxies: there is no proxy table, validator or fetch job — ProxyMate owns all of it.

## Rules

**The scraper class picks its client.**
`ApplyMate::Scraper::Base.http_client_class` is `ApplyMate::Client::ImpersonateHttp` (curl-impersonate — the tool ProxyMate checks every proxy with); no scraper overrides it today. Everything that needs a client for a source asks the scraper class, never hardcodes one:

```ruby
# Vacancy::Operation::SyncVacancies#build_scraper — one client + scraper per proxied request
client  = scraper_class.http_client_class.new(proxy: proxy.url, clearance: proxy.clearance,
                                              request_timeout: HTTP_REQUEST_TIMEOUT, connect_timeout: HTTP_CONNECT_TIMEOUT)
scraper = scraper_class.new(source, client)
```

Every proxied client class must therefore accept the `(proxy:, request_timeout:, connect_timeout:, clearance:)` constructor and answer two class predicates the pool turns into its ProxyMate request: `supported_proxy_protocols` (ProxyMate names: `http socks4 socks4a socks5 socks5h`) and `supports_cloudflare_clearance?` (`true` → `cloudflare: 'any'` + `impersonate_targets`; `false` would ask for `cloudflare: 'without'`).

**Scrapers only parse.**
A scraper receives `(source, client)`, makes the HTTP calls it needs through `@client` wrapped in `via_proxy`, and returns `ApplyMate::Operation::Struct`s. It does not touch the database, the proxy pool or Elasticsearch.

**Dead proxies are signalled, not swallowed.**
Transport failures, `429/502/503/504`, Cloudflare block/challenge pages and blocked/empty pages raise `ApplyMate::Scraper::Base::DeadProxyError` (a plain short reason as the message: `HTTP 403 Cloudflare`, `empty job list (proxy rate-limited)`, curl's error text); `SyncVacancies` drops that proxy from the pool for the round and retries the page on another. Nothing is reported to ProxyMate; the proxy comes back in the pool's next round (`.ai/docs/sync_vacancies.md`).

**Behaviour switches live in the scraper class API.**
`listing_url(source)`, `proxy_site` (ProxyMate site slug; no default — `NotImplementedError`), `fetches_description?`, `http_client_class` are class methods on `Scraper::Base`; callers (sync, totals widget) call them instead of comparing scraper names.

## Adding a new job board

1. Create `app/concepts/apply_mate/scraper/my_site.rb` inheriting `ApplyMate::Scraper::Base`: constructor `(source, client)`, `fetch_listing(page:)`; override `proxy_site` (required — the slug of the site in ProxyMate's `GET /api/v1/sites`; ask for the site to be added there first), `listing_url`, `http_client_class`, and (`fetches_description?` + `fetch_description(url)`) only if needed.
2. Add `'ApplyMate::Scraper::MySite'` to `Source::SCRAPERS` in `app/models/source.rb` (it validates inclusion and feeds the admin source form select).
3. Create the `Source` row (admin UI: name, `base_url`, logo, scraper). Seeds for development live in `db/seeds/development/`.
4. Add a spec for the scraper (see `.ai/docs/rspec.md`) — `SyncVacancies` picks the new source up through `Source.all`.
