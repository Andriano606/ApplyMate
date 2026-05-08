# Scrapers & HTTP Client

## Architecture

Scrapers live in `app/concepts/apply_mate/scraper/`. Each scraper inherits `ApplyMate::Scraper::Base` and implements:

| Method | Purpose |
|--------|---------|
| `fetch_listing` | Returns array of `ApplyMate::Operation::Struct` (one per vacancy) |
| `fetch_details(url)` | Returns enriched text details for a single vacancy URL |
| `fetch_applyble(url, session_id:)` | Returns `true`/`false` — can the user apply to this vacancy? |
| `fetch_form_data(url, session_id: nil)` | Returns a hash representing the HTML application form (inputs, action, method, cookies) |

Constructor always takes `(source, client)`:

```ruby
def initialize(source = Source.find_by(name: 'MySite'), client = ApplyMate::Client::Http.new)
  @source = source
  @client = client
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

`Vacancy::Job::SyncVacancies` iterates all sources and always passes `Client::Http` directly:

```ruby
vacancies_data = source.scraper.constantize.new(source, ApplyMate::Client::Http.new).fetch_listing
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

Call `initialize_session` at the top of `fetch_listing` before any XHR calls.

## Graceful termination

Check `Thread.main[:solid_queue_terminating]` inside the pagination loop so the job can be stopped cleanly (saves collected jobs and exits):

```ruby
loop do
  if Thread.main[:solid_queue_terminating]
    Rails.logger.info 'Termination signal received. Saving collected jobs and exiting...'
    break
  end
  # ... scrape page
  sleep(rand(2..5))
end
```

## HTML sanitization

`Html2Text.convert(html)` converts HTML to plain text. Strip excess whitespace if needed:

```ruby
def sanitize_html(html)
  return '' if html.blank?
  Html2Text.convert(html).gsub(/[\t\r\n]+/, ' ').gsub(/\s{2,}/, ' ').strip
end
```

Djinni uses the simpler `Html2Text.convert(html)` without the gsub strip — use whichever fits the source's HTML structure.
