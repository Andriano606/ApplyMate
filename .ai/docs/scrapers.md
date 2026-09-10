# Scrapers & HTTP Client

## Architecture

Scrapers live in `app/concepts/apply_mate/scraper/`. Each scraper inherits `ApplyMate::Scraper::Base` (which already `include`s `ApplyMate::Logging`) and implements:

| Method | Purpose |
|--------|---------|
| `fetch_listing(page:)` | Makes **one** HTTP request for that page/offset. Returns array of vacancy structs, or `nil` when the page is empty. No per-vacancy HTTP calls. |
| `fetch_description(url)` | Fetches a single vacancy's description and returns it as **HTML**. Called in the second async pass by `fetch_description_worker`. Only implemented by scrapers whose `fetches_description?` is `true`. |
| `fetch_details(url)` | Used by the **apply flow** (not sync). Returns structured details needed to fill an application form. |
| `fetch_applyble(url, session_id:)` | Returns `true`/`false` — can the user apply to this vacancy? |
| `fetch_form_data(url, session_id: nil)` | Returns a hash representing the HTML application form (inputs, action, method, cookies) |

### fetch_listing must stay pure

`fetch_listing` must make **exactly one** HTTP request and return immediately. Never call `fetch_description`, `fetch_details`, or any per-vacancy URL inside `fetch_listing` — that was a past mistake in Dou where the listing fetched each vacancy's details inline, blocking the entire page until all detail requests finished. Per-vacancy enrichment belongs exclusively in the second-pass `fetch_description_worker`.

### fetch_description vs fetch_details

These two methods serve different callers:

| | `fetch_description` | `fetch_details` |
|---|---|---|
| Called by | `SyncVacancies` second pass | Apply flow |
| Purpose | Enrich vacancy description in DB | Provide form/apply details |
| Returns | HTML string | plain text |
| Dou | ✅ implemented | empty |
| Djinni | not implemented | ✅ implemented |

`fetch_description` is called **only** when the scraper's `fetches_description?` is `true`
— `SyncVacancies` skips the whole second pass otherwise, so a source whose listing already
carries the description (Djinni) must not define the method at all. Returning a sentinel
string from it to make the pipeline stop is what this predicate replaced.

Constructor always takes `(source, client)` — both required, since the caller decides
which transport and which proxy this instance runs on:

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
  description:,       # plain text — Elasticsearch, AI prompts, card preview
  description_html:,  # the source's own markup — what the vacancy page renders
  company_name:,
  company_icon_url:,
  external_id:        # unique identifier on the source site (string)
)
```

Only listing-carries-the-description sources (`fetches_description?` == `false`) fill the two
description keys here; for the others the listing must leave both out so the second pass owns
them (see `.ai/docs/sync_vacancies.md`).

## Source#build_scraper

`Source` has a `build_scraper` helper that instantiates the configured scraper with the
client that scraper class asks for. Scrapers never receive `Client::Browser`:

```ruby
scraper = source.build_scraper
# equivalent to:
klass   = source.scraper.constantize
scraper = klass.new(source, klass.http_client_class.new)
```

`Scraper::Base.http_client_class` returns `ApplyMate::Client::AsyncHttp` (15s request
timeout, 5s connect). Override it per source when the default transport can't reach the
site — `Scraper::Dou` returns `ApplyMate::Client::ImpersonateHttp` to clear Cloudflare.
`Source#http_client(**options)` builds the same class with different timeouts, which is
how `SendApply::Http` submits through the source's own fingerprint.

Use this in operations that need a scraper from an `apply` record:

```ruby
scraper = apply.vacancy.source.build_scraper
```

## Cloudflare-protected sites — ImpersonateHttp (TLS fingerprint, no browser)

Some sources (e.g. **Dou** = `jobs.dou.ua`) sit behind **Cloudflare**. A raw request
(`AsyncHttp`/`Http`) gets a **403 "Just a moment…"** page regardless of HTTP headers —
masking `Accept`/`Sec-*` does not help (measured: 22 vs 20 of 120 proxies). The discriminator
is the **TLS/JA3 fingerprint**: Ruby's OpenSSL handshake isn't Chrome's, so Cloudflare blocks it.

**`ApplyMate::Client::ImpersonateHttp`** solves this by shelling out to **curl-impersonate**
(BoringSSL with Chrome's exact cipher/extension order + HTTP/2 settings). It passes the
non-interactive Cloudflare challenge **without a browser, at HTTP speed**, and is a **drop-in
for `AsyncHttp`** (same `Response`, `#get`/`#post`):

```ruby
client  = ApplyMate::Client::ImpersonateHttp.new(proxy: proxy.url)
scraper = ApplyMate::Scraper::Dou.new(source, client)   # ImpersonateHttp stands in for AsyncHttp
scraper.fetch_listing(page: 1)                          # GET CSRF + POST xhr-load — both via curl-impersonate
scraper.fetch_description(url)                           # GET detail page
```

Measured (datacenter proxies that raw HTTP can't use): **~43%** become usable via the Chrome TLS
fingerprint, and a usable proxy sustains **12–15/15** sequential requests (no quick ban). The
remaining proxies split into a true JS-challenge minority and hard IP-blocks (1020) — see
`.ai/docs/proxy.md`. Compare a real headless browser: it also passes CF but yields only **~2
pages per proxy before a ban** and carries full Chrome overhead — so ImpersonateHttp is the
primary path; `ApplyMate::Client::Browser` is reserved for the rare interactive JS challenge.

**Install:** the curl-impersonate binary is arch-specific and NOT committed. Run
`bin/install-curl-impersonate` once per host (downloads into `vendor/curl-impersonate/`, which is
gitignored). Override the binary path with `CURL_IMPERSONATE_BIN` (e.g. a `curl_chrome136`
wrapper already on the host).

**Concurrency:** `ImpersonateHttp` shells out via `Open3`, but the `async` reactor hooks
`process_wait`, so a fiber **yields** while its curl subprocess runs — 8 concurrent requests
measured 0.07s vs 0.46s sequential. So it cooperates with the existing **50-fiber** model in
`SyncVacancies`; no thread pool is needed. A source selects its client via
`Scraper.http_client_class` (Dou → `ImpersonateHttp`, default → `AsyncHttp`); both share the
`(proxy:, request_timeout:, connect_timeout:)` constructor, so the pool/workers build either one
interchangeably.

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

`Source::SCRAPERS` lists allowed class name strings. Add the new class there and add a migration to backfill existing rows.

## Adding a new scraper

1. Create `app/concepts/apply_mate/scraper/my_site.rb` inheriting `ApplyMate::Scraper::Base`
2. Add `'ApplyMate::Scraper::MySite'` to `Source::SCRAPERS` in `app/models/source.rb`
3. Add migration: `add_column :sources, :scraper, :string` (if not yet present) + backfill migration
4. Update the admin form select (uses `Source::SCRAPERS` collection)

## HTTP client API

`ApplyMate::Client::AsyncHttp` and `ApplyMate::Client::ImpersonateHttp` expose the same
surface, so a scraper works unchanged on either. Requests fail fast — neither client
retries internally; the sync pipeline handles retries by swapping the proxy.

```ruby
client = ApplyMate::Client::AsyncHttp.new                      # 15s request, 5s connect
client = ApplyMate::Client::AsyncHttp.new(proxy: 'http://user:pass@host:port',
                                          request_timeout: 30, connect_timeout: 5)
```

Every request returns an `ApplyMate::Client::Response` — `.body`, `.headers`, `.status`,
`.final_url` — shared by both clients so the struct cannot drift between transports:

```ruby
# GET — follows redirects by default; pass follow_redirects: false to inspect a 3xx
response = client.get(url)
response = client.get(url, headers: { 'Cookie' => '...' })
response = client.get(url, follow_redirects: false)

# POST — body is an already-encoded String (e.g. URI.encode_www_form(count: 0))
response = client.post(url, body: URI.encode_www_form(count: 0), headers: xhr_headers)

# Multipart POST — never follows redirects, so form submissions can inspect the 3xx
# themselves to detect apply success. File parts: Faraday::Multipart::FilePart, or any
# object responding to read/original_filename/content_type.
response = client.post_multipart(url, payload: { field: 'value', cv: file_part },
                                 headers: { 'Cookie' => '...' })
response.status          # Integer
response.headers         # Hash — check 'location' for redirects
response.body            # String
response.final_url       # String — where the redirect chain ended
```

`Response` also answers the two checks the proxy validator and the sync probe share:
`cloudflare_challenge?` (body still shows the "Just a moment…" interstitial) and
`alive_or_cf_challenge?` (2xx/3xx, or a 403 that is a CF challenge rather than an IP
block). There is no `success?` — compare `status` yourself.

`ImpersonateHttp` shells out to curl-impersonate and raises
`ApplyMate::Client::ImpersonateHttp::RequestError` when the subprocess exits non-zero.

## CSRF session init pattern (DOU-style XHR scrapers)

Some sites require a CSRF token extracted from cookies before XHR requests will succeed. Pattern:

```ruby
def initialize_session
  response = @client.get(VACANCIES_URL)
  csrf_match = response&.headers&.[]('set-cookie').to_s.match(/csrftoken=([^;,\s]+)/)
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
raise ApplyMate::Client::Base::DeadProxyError, 'could not extract CSRF token (proxy blocked)' if @csrf_token.blank?
```

## Proxy-blocked responses — raise DeadProxyError

When a proxy is blocked the site returns HTML instead of expected content. Two guards:

**JSON endpoints** — wrap `JSON.parse` and re-raise so the worker retries with a fresh proxy:

```ruby
begin
  data = JSON.parse(body)
rescue JSON::ParserError
  raise ApplyMate::Client::Base::DeadProxyError, 'non-JSON response (proxy blocked)'
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
| `description_html` | the source's markup, kept as-is | `Vacancy::Component::InfoCard` → `ApplyMate::Component::RichText` |
| `description` | plain-text projection of that markup | Elasticsearch `as_indexed_json`, AI prompts, `Vacancy::Component::Card` preview |

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
