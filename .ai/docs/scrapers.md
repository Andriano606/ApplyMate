# Scrapers & HTTP Client

## Architecture

Scrapers live in `app/concepts/apply_mate/scraper/`. Each scraper inherits `ApplyMate::Scraper::Base` (which already `include`s `ApplyMate::Logging`) and implements:

| Method | Purpose |
|--------|---------|
| `fetch_listing(page:)` | Makes **one** HTTP request for that page/offset. Returns array of vacancy structs, or `nil` when the page is empty. No per-vacancy HTTP calls. |
| `fetch_description(url)` | Fetches a single vacancy's description and returns it as **HTML**. Called in the second async pass by `fetch_description_worker`. Only implemented by scrapers whose `fetches_description?` is `true`. |

### fetch_listing must stay pure

`fetch_listing` must make **exactly one** HTTP request and return immediately. Never call `fetch_description` or any per-vacancy URL inside `fetch_listing` — that was a past mistake in Dou where the listing fetched each vacancy's details inline, blocking the entire page until all detail requests finished. Per-vacancy enrichment belongs exclusively in the second-pass `fetch_description_worker`.

### fetch_description

`fetch_description` is called **only** when the scraper's `fetches_description?` is `true`
— `SyncVacancies` skips the whole second pass otherwise, so a source whose listing already
carries the description (Djinni) must not define the method at all. Returning a sentinel
string from it to make the pipeline stop is what this predicate replaced.

Constructor always takes `(source, client)`:

```ruby
def initialize(source, client)
  @source = source
  @client = client
end
```

## fetch_listing pagination contract

`fetch_listing` makes exactly **one** HTTP request and returns an array of vacancy structs (or `nil` when the page is empty) — `SyncVacancies` drives the loop:

```ruby
# returns nil to signal the last page
def fetch_listing(page:)
  # ... fetch one page ...
  nodes = doc.css('.job-list-item')
  return if nodes.empty?

  nodes.map { |el| extract_job_data(el) }
end
```

## Vacancy struct shape

`fetch_listing` must return an array of `ApplyMate::Operation::Struct` with these keys (matches `Vacancy` columns used in `upsert_all`):

```ruby
ApplyMate::Operation::Struct.new(
  source_id:,
  title:,
  url:,
  description:,       # plain text — Elasticsearch, card preview
  description_html:,  # the source's own markup — what the vacancy page renders
  company_name:,
  company_icon_url:,
  external_id:        # unique identifier on the source site (string)
)
```

Only listing-carries-the-description sources (`fetches_description?` == `false`) fill the two
description keys here; for the others the listing must leave both out so the second pass owns
them (see `.ai/docs/sync_vacancies.md`).

## Building a scraper

`SyncVacancies` instantiates the configured scraper with the client class the scraper declares (`Scraper.http_client_class` — `ImpersonateHttp` for every source; no scraper overrides it), one client per proxied request:

```ruby
scraper_class = source.scraper.constantize          # hoisted out of the worker loop
client        = scraper_class.http_client_class.new(proxy: proxy.url, clearance: proxy.clearance, request_timeout:, connect_timeout:)
scraper       = scraper_class.new(source, client)
```

`proxy` is an `ApplyMate::Client::ProxyMate::Proxy` (`id`, `url`, `protocol`, `clearance`) handed out by ProxyMate for the scraper's `proxy_site`.

## The client — ImpersonateHttp (browser TLS fingerprint, no browser)

Every source goes through **`ApplyMate::Client::ImpersonateHttp`**, which shells out to
**curl-impersonate** (BoringSSL with a browser's exact cipher/extension order + HTTP/2
settings). Two reasons:

- **ProxyMate checks every proxy with curl-impersonate.** "Working for djinni" in ProxyMate
  means "working through curl-impersonate with `chrome146`" — the same request is what the
  sync makes, so ProxyMate's verdict holds for it, and every source can use proxies that come
  with a Cloudflare token (`cloudflare: 'any'` + `impersonate_targets`, via the client's
  predicates).
- **Cloudflare** (e.g. **Dou** = `jobs.dou.ua`) answers an OpenSSL TLS/JA3 fingerprint with a
  **403 "Just a moment…"** regardless of HTTP headers (measured: masking `Accept`/`Sec-*` gave
  22 vs 20 of 120 proxies). curl-impersonate passes the non-interactive challenge **without a
  browser, at HTTP speed**.

```ruby
client  = ApplyMate::Client::ImpersonateHttp.new(proxy: proxy.url)
scraper = ApplyMate::Scraper::Dou.new(source, client)
scraper.fetch_listing(page: 1)                          # GET CSRF + POST xhr-load — both via curl-impersonate
scraper.fetch_description(url)                           # GET detail page
```

Measured (datacenter proxies that raw HTTP can't use): **~43%** become usable via the Chrome TLS
fingerprint, and a usable proxy sustains **12–15/15** sequential requests (no quick ban). The
remaining proxies split into a true JS-challenge minority and hard IP-blocks (1020). A real headless browser also passes CF but yields only **~2
pages per proxy before a ban** and carries full Chrome overhead — so ImpersonateHttp is the
primary path for Cloudflare-protected sources.

**Fingerprint:** every request runs `curl-impersonate --impersonate <target> --compressed`.
The target is `ImpersonateHttp::DEFAULT_IMPERSONATE` (`chrome146` — the one ProxyMate checks
proxies with), or, for a proxy ProxyMate handed out with a Cloudflare clearance, the
clearance's own `impersonate` (a Firefox target). With a clearance the client also sends its
`User-Agent` and appends its `cf_clearance` cookie to the scraper's `Cookie` header (one header:
`csrftoken=…; cf_clearance=…`) — Cloudflare binds the token to proxy IP + UA + fingerprint.
Proxies: `socks5://` is sent as `socks5h://` (remote DNS); `http`, `socks4`, `socks4a`, `socks5h`
pass through (curl speaks all of them).

**Install:** the curl-impersonate binary is arch-specific and NOT committed. Run
`bin/install-curl-impersonate` once per host (downloads the release pinned as the script's
`CURL_IMPERSONATE_VERSION` default, v2.3.3, into `vendor/curl-impersonate/`, which is gitignored;
exits non-zero unless `--impersonate chrome146` runs). `ImpersonateHttp::RELEASE` reads that pin
from the script — the one place it lives. At run start the sync compares it with ProxyMate's
`GET /api/v1/meta` `curl_impersonate.release`: equal → it asks ProxyMate for tokens bound to any
of ProxyMate's `targets`; different (or meta unavailable) → only `DEFAULT_IMPERSONATE`, with a
`vacancy_sync_curl_impersonate_mismatch` warning. Override the path with `CURL_IMPERSONATE_BIN`
(the `curl-impersonate` binary itself, not a `curl_chrome*` wrapper). A binary that cannot start
raises `ImpersonateHttp::BinaryError` — never a `DeadProxyError`, so a broken host cannot burn
the proxy pool.

**Concurrency:** `ImpersonateHttp` shells out via `Open3`, but the `async` reactor hooks
`process_wait`, so a fiber **yields** while its curl subprocess runs — 8 concurrent requests
measured 0.07s vs 0.46s sequential; no thread pool is needed. The number of curl subprocesses
is capped process-wide in the client: `ImpersonateHttp::MAX_PROCESSES` (ENV
`CURL_IMPERSONATE_MAX_PROCESSES`, default 64, read in `impersonate_http.rb`) — every source and
phase shares it; the sync's `WORKERS_PER_SOURCE` / `DESCRIPTION_WORKERS` (32 each, two sources at
once) fill it exactly, and any extra fiber waits for a slot (see `.ai/docs/async.md`).

## SyncVacancies job dispatch

`Vacancy::Operation::SyncVacancies` calls `fetch_listing(page:)` per worker, treating `nil` as the stop signal:

```ruby
listing = scraper.fetch_listing(page: page)

if listing&.any?
  sync_vacancies_batch(listing, source)
  all_external_ids.concat(listing.map(&:external_id))
else
  pages_queue.clear   # signals all other workers to stop
  break
end
```

`Source::SCRAPERS` lists allowed class name strings. Add the new class there.

## Adding a new scraper

1. Create `app/concepts/apply_mate/scraper/my_site.rb` inheriting `ApplyMate::Scraper::Base`
2. Add `'ApplyMate::Scraper::MySite'` to `Source::SCRAPERS` in `app/models/source.rb` (the admin source form select reads this constant)
3. Create the `Source` row with `scraper: 'ApplyMate::Scraper::MySite'`
4. Declare `proxy_site` (the ProxyMate site slug — required) and override as needed: `listing_url`, `fetches_description?` (`http_client_class` is `ImpersonateHttp` for everyone)

See `.ai/docs/architecture.md`.

## Client API (`ImpersonateHttp`)

Constructor `(proxy: nil, request_timeout:, connect_timeout:, clearance: nil)`, class predicates `supported_proxy_protocols` (`http socks4 socks4a socks5 socks5h`) and `supports_cloudflare_clearance?` (`true`) — the sync pool turns them into its ProxyMate request. Requests fail fast — there is no internal retrying. Returns `ImpersonateHttp::Response` (`.body`, `.headers`, `.status`, `.final_url`); a failed curl raises `ImpersonateHttp::RequestError` (message: `curl-impersonate failed (exit N): <curl's errormsg>`).

```ruby
client = ApplyMate::Client::ImpersonateHttp.new(proxy: proxy.url, clearance: proxy.clearance)

response = client.get(url)
response = client.get(url, headers: { 'Cookie' => '...' })
response = client.post(url, body: URI.encode_www_form(count: 0), headers: xhr_headers)
```

Redirects are always followed (`curl -L`); `response.final_url` is curl's `url_effective`, so compare it with the requested URL to detect a redirect (Djinni's last page redirects back to `/jobs/`). Inside a scraper always wrap calls in `via_proxy { ... }`: transport errors, `PROXY_DEAD_STATUSES` (`429 502 503 504`) and a Cloudflare block/challenge page at any non-200 status become `DeadProxyError`.

## Dead proxies — `DeadProxyError`

`DeadProxyError` is a plain `StandardError`; its message is a short reason. `via_proxy` raises it
for a transport failure (`transport failure (<error class>: <curl's message>)`), a
`PROXY_DEAD_STATUSES` reply (`HTTP 429`) and a Cloudflare block/challenge page at a non-200
status (`HTTP 403 Cloudflare`; `cloudflare_page?` — `<title>Just a moment`, `_cf_chl_opt`,
`cf-chl`, `<title>Attention Required! | Cloudflare` / `Access denied`). A scraper raises it
itself when a page gives the proxy away — `raise DeadProxyError, 'empty job list (proxy
rate-limited)'` (empty list, non-JSON, no CSRF cookie). The sync only counts it (`dead_proxies`)
and drops the proxy for the round; nothing is reported to ProxyMate.

## CSRF session init pattern (DOU-style XHR scrapers)

Some sites require a CSRF token extracted from cookies before XHR requests will succeed. Pattern:

```ruby
def initialize_session
  response = via_proxy { @client.get(VACANCIES_URL) }
  csrf_match = Array(response.headers['set-cookie']).join('; ').match(/csrftoken=([^;,\s]+)/)
  @csrf_token = csrf_match&.[](1)
end

def xhr_headers
  {
    'X-Requested-With' => 'XMLHttpRequest',
    'X-CSRFToken'      => @csrf_token.to_s,
    'Referer'          => VACANCIES_URL,
    'Cookie'           => "csrftoken=#{@csrf_token}",
    'Content-Type'     => 'application/x-www-form-urlencoded'
  }
end
```

Call `initialize_session` at the top of `fetch_listing` (not in the constructor). `SyncVacancies` creates the scraper per page with a new proxy client each time, so constructor-time HTTP calls waste a request every page.

If CSRF extraction fails (proxy served a captcha), raise `DeadProxyError` immediately — continuing with a nil token causes every subsequent request to fail silently:

```ruby
raise DeadProxyError, 'could not extract CSRF token (proxy blocked)' if @csrf_token.blank?
```

## Proxy-blocked responses — raise DeadProxyError

When a proxy is blocked the site returns HTML instead of expected content. Two guards:

**JSON endpoints** — wrap `JSON.parse` and re-raise so the worker retries with a fresh proxy:

```ruby
begin
  data = JSON.parse(body)
rescue JSON::ParserError
  raise DeadProxyError, 'non-JSON response (proxy blocked)'
end
```

**CSRF/session init** — raise in `initialize_session` if the token is blank (see above).

Both propagate to `scrape_pages`' `rescue DeadProxyError`, which releases the proxy and retries the same page with a new one.

## Logging

`ApplyMate::Scraper::Base` includes `ApplyMate::Logging`, so all scrapers inherit `log`. Use it instead of `Rails.logger`:

```ruby
log "Scraping page #{page}: #{url}"                                  # yellow info (default)
log 'Could not extract CSRF token', color: :red, level: :warn        # red warn
```

Never call `Rails.logger` directly inside a scraper.

## Descriptions: markup in, text derived

A vacancy description is stored twice, and a scraper must produce both from the **same**
string so they can never describe different content:

| Column | Content | Read by |
|---|---|---|
| `description_html` | the source's markup, kept as-is | `Vacancy::Component::Show` → `rich_text` → `ApplyMate::Component::RichText` |
| `description` | plain-text projection of that markup | Elasticsearch `as_indexed_json`, `Vacancy::Component::Card` preview |

`ApplyMate::Scraper::Base` owns both halves — never hand-roll tag stripping in a scraper:

```ruby
# Inner HTML of a description node, minus NON_CONTENT_TAGS (script/style/iframe/…),
# NON_CONTENT_ATTRIBUTES (class/style) and NON_CONTENT_ATTRIBUTE_PREFIXES (on*, data-*).
# Structure and emphasis are kept on purpose.
html = content_html(node)

# Plain-text projection (Html2Text).
text = self.class.to_plain_text(html)
```

Scope the node to the description **body**, not the page wrapper: once the result is rendered
as markup rather than flattened to text, share widgets, tracking scripts and reply buttons
show up as visible noise (Dou: `div.b-typo.vacancy-section`, not `div.l-vacancy`). If a scraper
also prepends a node from *outside* that scope (Dou's `div.sh-info`), do it only on the narrow
branch — on the wrapper fallback that node is already inside the markup.

Storing markup is safe because nothing renders it directly — `ApplyMate::Component::RichText`
re-sanitises against a tag allow-list at render time. Views pass **both** columns
(`rich_text(html: v.description_html, text: v.description)`); the component falls back to
`simple_format(text)` for rows scraped before markup was stored, and guards render on
`Vacancy#description_present?`. Keep the write faithful; keep the render strict.
