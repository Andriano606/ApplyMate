# Scrapers & HTTP Client

## Architecture

Scrapers live in `app/concepts/apply_mate/scraper/`. Each scraper inherits `ApplyMate::Scraper::Base` (which already `include`s `ApplyMate::Logging`) and implements:

| Method | Purpose |
|--------|---------|
| `fetch_listing(page:, segment:)` | Makes **one** HTTP request for that page/offset of one listing segment. Returns array of vacancy structs, or `nil` when the page is empty. No per-vacancy HTTP calls. Sources with a single segment take `**` and ignore it. |
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

## Listing segments (`listing_segments`)

`SyncVacancies` paginates a source's listing one **segment** at a time: each segment
gets its own page range `1..MAX_PAGES` and its own end-of-listing detection (empty page
confirmations, boundary), so the end of one segment never cuts another short. The
scraper class lists them; `fetch_listing` receives one as `segment:`.

| Scraper | `listing_segments` | Why |
|---|---|---|
| `Base` (Dou, Djinni) | `[ nil ]` | one continuous listing |
| `Robota` | `PROF_LEVEL_IDS` = `0..6` | the search API answers nothing past offset 80 000, the listing is ~98k |

Segments may overlap (persist dedups by `external_id`), but **together they must cover the
whole listing** — a vacancy no segment lists is deleted as stale after the run. Robota's
career-level slices are disjoint and sum exactly to the unfiltered total (measured; see the
comment on `PROF_LEVEL_IDS` for how to re-measure if robota adds a level — nothing checks it
at run time).

Two safety rules protect the stale cleanup from a segment that only *looks* complete:

- **A segment that listed nothing skips the cleanup for the run** (`empty_segments` > 0 in
  `vacancy_sync_listing_finished`, `stale_deleted: 0`). It generalises the old single-listing
  rule ("an empty listing must not wipe the source"). The price: a legitimately empty segment
  keeps stale rows until it lists something again — every Robota level is populated.
- **`ApplyMate::Scraper::Base::IncompleteListingError`** — a scraper raises it when the source
  shows the run can't see the whole listing (Robota: a segment's `total` is over the search
  window). `SyncVacancies` doesn't retry it: it stops the source's workers, flushes what was
  scraped and fails the listing phase, so nothing is deleted.

## End of listing reported by the source (`listing_end_reported?`)

`SyncVacancies` normally believes an empty page only after `LAST_PAGE_CONFIRMATIONS` (50)
empty answers — an empty page can be an anti-scraping blip. A scraper whose `fetch_listing`
returns `nil` only when the source itself said the listing ended returns `true` from
`listing_end_reported?`, and the first `nil` ends the segment. Robota does (`offset >= total`,
`total` comes with every page): with 50 confirmations each of its 7 segments re-asked the
throttled API hundreds of times past its end. Dou/Djinni keep the default `false`.

## fetch_listing pagination contract

`fetch_listing` makes exactly **one** HTTP request and returns an array of vacancy structs (or `nil` when the page is empty) — `SyncVacancies` drives the loop:

```ruby
# returns nil to signal the last page
def fetch_listing(page:, **)
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

`SyncVacancies` instantiates the configured scraper with the client class the scraper declares (`Scraper.http_client_class`: `AsyncHttp` by default, `ImpersonateHttp` for Dou and Robota), one client per proxied request:

```ruby
scraper_class = source.scraper.constantize
client        = scraper_class.http_client_class.new(proxy: proxy.url, request_timeout:, connect_timeout:)
scraper       = scraper_class.new(source, client)
```

## Cloudflare-protected sites — ImpersonateHttp (TLS fingerprint, no browser)

Some sources (**Dou** = `jobs.dou.ua`, **Robota** = `api.robota.ua`) sit behind **Cloudflare**. A raw request
(`AsyncHttp`) gets a **403 "Just a moment…"** page regardless of HTTP headers —
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
`.ai/docs/proxy.md`. A real headless browser also passes CF but yields only **~2
pages per proxy before a ban** and carries full Chrome overhead — so ImpersonateHttp is the
primary path for Cloudflare-protected sources.

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

`Vacancy::Operation::SyncVacancies` walks `Scraper.listing_segments` in turn (`scrape_segment`); within a segment each worker calls `fetch_listing(page:, segment:)`, treating an empty result (`nil` or `[]`) as a candidate end of **that segment**:

```ruby
listing = scraper.fetch_listing(page:, segment:)

if listing&.any?
  buffer.add(listing)                               # RAM buffer, bulk-upserted on its limit
  external_ids.concat(listing.map(&:external_id))   # shared by all segments → clean_old_vacancies
else
  # counted per page; LAST_PAGE_CONFIRMATIONS empty answers set the segment's boundary
end
```

Details (confirmations, boundary, retries): `.ai/docs/sync_vacancies.md`.

`Source::SCRAPERS` lists allowed class name strings. Add the new class there.

## Adding a new scraper

1. Create `app/concepts/apply_mate/scraper/my_site.rb` inheriting `ApplyMate::Scraper::Base`
2. Add `'ApplyMate::Scraper::MySite'` to `Source::SCRAPERS` in `app/models/source.rb` (the admin source form select reads this constant)
3. Create the `Source` row with `scraper: 'ApplyMate::Scraper::MySite'`
4. Override class methods as needed: `listing_url`, `validation_url`, `http_client_class`, `fetches_description?`, `burst_cooldown`, `listing_segments`

See `.ai/docs/architecture.md`.

## Client API (`AsyncHttp` / `ImpersonateHttp`)

Both share the constructor `(proxy: nil, request_timeout:, connect_timeout:)` and the same methods. Requests fail fast — there is no internal retrying. Both return `ApplyMate::Client::Response` (`.body`, `.headers`, `.status`, `.final_url`).

```ruby
client = ApplyMate::Client::AsyncHttp.new(proxy: proxy.url)

response = client.get(url)
response = client.get(url, headers: { 'Cookie' => '...' })
response = client.post(url, body: URI.encode_www_form(count: 0), headers: xhr_headers)
```

Redirects are followed by default (`MAX_REDIRECTS = 5`); compare `response.final_url` with the requested URL to detect a redirect (Djinni uses this to detect the last page). Inside a scraper always wrap calls in `via_proxy { ... }` so transport errors, `nil` responses and `502/503/504` become `DeadProxyError`.

`Response` also has `cloudflare_challenge?` and `alive_or_cf_challenge?` (used by proxy validation).

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

## JSON-API sources (Robota)

robota.ua is an Angular SPA — its HTML pages are an empty shell without a browser — so
`ApplyMate::Scraper::Robota` reads the JSON API the SPA itself calls, through
`ImpersonateHttp` (plain `AsyncHttp` gets Cloudflare's 403):

| Pass | Request | Returns |
|---|---|---|
| listing | `POST https://api.robota.ua/vacancy/search` `{page (0-based), count: PAGE_SIZE (100), profLevelIds: [segment]}` | `total` + `documents` (title, company, logo, `notebookId`, ~250-char teaser) |
| description | `GET https://api.robota.ua/vacancy?id=<id>` (id taken from the stored page URL) | `description` — the employer's copy as one HTML document |

- **Vacancy URL** is the public page `https://robota.ua/company<notebookId>/vacancy<id>`; the
  description pass parses the id back out of it.
- **End of a segment is known, not guessed** (`listing_end_reported?` → `true`): every page
  carries `total`, so an empty page at `offset >= total` returns `nil`, an empty page short of
  it raises `DeadProxyError` (throttled answer). A page at `offset >= MAX_RESULT_WINDOW`
  (80 000) returns `nil` without a request; a page whose `total` exceeds the window raises
  `IncompleteListingError` (also what happens if robota stops honouring `profLevelIds` — every
  segment then reports the unfiltered ~98k).
- **403 / 429 / a 200 that isn't JSON** → `DeadProxyError` (Cloudflare challenge, throttling, a
  proxy's own page). **Any other non-200, or JSON without integer `total` + array `documents`**
  → `Robota::UnexpectedResponseError` (robota's side: retried without marking the proxy dead).
  **404** on the vacancy endpoint → `nil` (closed since the listing; the next listing drops it).
- **Which part of the page is the description:** the vacancy page shows the header (title,
  salary, city, tags), the employer's description, contacts, the company card, similar and
  recommended vacancies and a CV promo. Only the description is the employer's copy, and the
  API returns it as its own field, so nothing has to be cut out — the scraper takes the
  `<body>` of that field through `content_html`. The salary exists only in the header, so it is
  prepended as one paragraph (`vacancy.sync.salary.range` / `.exact` + `salaryComment`). City,
  badges and clusters are not used: the API returns them in Russian only.
- **Logo:** `https://logo-frankfurt.cf-rabota.com.ua/<logo>`; robota's `defaultlogo.gif`
  placeholder becomes `nil`.
- **Proxy validation** probes `GET https://api.robota.ua/vacancy/search?count=1`
  (`validation_url`) — the host both passes call — not the SPA shell (`listing_url`, used for
  the totals widget link).
