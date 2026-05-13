# Scrapers & HTTP Client

## Architecture

Scrapers live in `app/concepts/apply_mate/scraper/`. Each scraper inherits `ApplyMate::Scraper::Base` (which already `include`s `ApplyMate::Logging`) and implements:

| Method | Purpose |
|--------|---------|
| `fetch_listing(page:)` | Makes **one** HTTP request for that page/offset. Returns array of vacancy structs, or `nil` when the page is empty. No per-vacancy HTTP calls. |
| `fetch_description(url)` | Fetches and returns enriched description text for a single vacancy. Called in the second async pass by `fetch_description_worker`. Empty for scrapers that don't support it. |
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
| Dou | ✅ implemented | empty |
| Djinni | empty | ✅ implemented |

A scraper that returns empty from `fetch_description` is valid — the second-pass worker checks `description.present?` and skips the update.

Constructor always takes `(source, client)`:

```ruby
def initialize(source = Source.find_by(name: 'MySite'), client = ApplyMate::Client::Http.new)
  @source = source
  @client = client
end
```

## fetch_listing pagination contract

`fetch_listing` makes exactly **one** HTTP request and returns an array of vacancy structs (or `nil` when the page is empty) — `SyncVacancies` drives the loop:

```ruby
# returns nil to signal the last page
def fetch_listing(page:)
  check_termination!
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
  description:,       # sanitized plain text
  company_name:,
  company_icon_url:,
  external_id:        # unique identifier on the source site (string)
)
```

## Source#build_scraper

`Source` has a `build_scraper` helper that instantiates the configured scraper with `Client::Http` (default 15s timeout). The client is always `Http` — scrapers never receive `Client::Browser`:

```ruby
scraper = source.build_scraper
# equivalent to:
scraper = source.scraper.constantize.new(source, ApplyMate::Client::Http.new)
```

Use this in operations that need a scraper from an `apply` record:

```ruby
scraper = apply.vacancy.source.build_scraper
```

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

## ApplyMate::Client::Http API

All methods use the shared Faraday connection (browser User-Agent, follow redirects, 15s timeout) with exponential-backoff retries via `ApplyMate::Client::ErrorHandler` (5 retries, 1s base delay).

Returns a `Response` struct: `.body`, `.headers`, `.status`.

```ruby
client = ApplyMate::Client::Http.new

# GET — returns Response or nil on redirect to unexpected URL
response = client.get(url)
response = client.get(url, headers: { 'Cookie' => '...' })

# GET — follow redirects (skips the nil-on-redirect guard)
# Use when the target URL is expected to redirect (e.g. external employer apply pages)
response = client.get(url, follow_redirects: true)

# Convenience: GET body only
body = client.fetch_body(url)

# POST — returns Response
response = client.post(url, body: form_encoded_string, headers: {})

# Convenience: POST body only (for XHR endpoints)
body = client.post_xhr(url, URI.encode_www_form(count: 0), xhr_headers)
```

`get` returns `nil` (body is `nil`) if the server redirects to a different URL than requested — log and skip rather than raise. Pass `follow_redirects: true` to bypass this guard when redirects are expected (e.g. `Apply::Operation::Ai::FetchExternalForm`).

`Response` also has `success?` which returns true for 2xx status codes.

```ruby
# Multipart POST without redirect-following — use for form submissions where
# you need to inspect 3xx responses yourself (e.g. to detect apply success).
# File parts: use Faraday::Multipart::FilePart in the payload hash.
client = ApplyMate::Client::Http.new(timeout: 30)
response = client.post_multipart(url, payload: { field: 'value', file_field: file_part }, headers: { 'Cookie' => '...' })
response.success?        # true for 2xx
response.status          # Integer
response.headers         # Hash (check 'location' for redirects)
response.body            # String
```

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

## Graceful termination

Call `check_termination!` (inherited from `Base`) at the start of `fetch_listing`. It reads `Thread.main.thread_variable_get(:solid_queue_terminating)` and raises `TerminationError` if set. Because the pagination loop now lives in `SyncVacancies`, a single `check_termination!` per `fetch_listing` call is sufficient — no manual loop checks needed in the scraper itself.

## HTML sanitization

`Html2Text.convert(html)` converts HTML to plain text. Strip excess whitespace if needed:

```ruby
def sanitize_html(html)
  return '' if html.blank?
  Html2Text.convert(html).gsub(/[\t\r\n]+/, ' ').gsub(/\s{2,}/, ' ').strip
end
```

Djinni uses the simpler `Html2Text.convert(html)` without the gsub strip — use whichever fits the source's HTML structure.
