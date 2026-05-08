# Apply Pipeline Architecture

## Module Boundaries

These are enforced boundaries, not guidelines. Violating them causes cross-layer coupling that breaks the separation between transport and domain logic.

| Module | Responsibility | Uses |
|--------|---------------|------|
| `ApplyMate::Client::Http` | Low-level HTTP transport: GET/POST/multipart, headers, timeouts, redirects | Faraday |
| `ApplyMate::Client::Browser` | Low-level browser transport: navigate, click, fill field, screenshot, stealth, reCAPTCHA | Ferrum |
| `ApplyMate::Scraper::*` | Source-specific parsing: listing, details, applyble, apply_type, form_selector. **Never uses `Client::Browser`** | `Client::Http` |
| `Apply::Handler::*` | Declares the pipeline via `add_step`. Owns source-specific prompt/schema class knowledge | — |
| `Apply::Operation::*` | Orchestrates one pipeline step: uses scraper + client, persists result to `apply` | `Client::Http` or `Client::Browser` |

## Rules

**Scrapers always get `Client::Http`.**
`Source#build_scraper` hardcodes `ApplyMate::Client::Http.new` regardless of any source config. Scrapers only parse HTML — they never need a browser.

```ruby
def build_scraper
  self.scraper.constantize.new(self, ApplyMate::Client::Http.new)
end
```

**Operations instantiate their own client.**
`SyncVacancies`, `SendApply::Http`, and any operation that needs HTTP always instantiate `ApplyMate::Client::Http.new` directly. The client is not sourced from the database.

**Browser is for operations, not scrapers.**
`Client::Browser` is used only in `Apply::Operation::*` (e.g. `FetchExternalForm`, `SendApply::Browser`) to automate a headless Chrome session for submitting or scraping content that requires real interaction.

**Handler resolution is name-based.**
The handler class is derived from the source's scraper class name:

```ruby
scraper_name = apply.source_profile.source.scraper.demodulize  # "Djinni" or "Dou"
"Apply::Handler::#{scraper_name}".constantize.new(apply:)
```

Adding a new job board requires: a new `Scraper::MySite`, a new `Handler::MySite` with `add_step` pipeline, and adding the scraper class to `Source::SCRAPERS`.

## Client::Browser public API

Two modes of use:

**Self-contained (open page, do work, close page):**
```ruby
page_url, body, cookies         = browser.fetch_rendered(url)
page_url, body, cookies, unique = browser.click_and_fetch(url, selector)
```

**Multi-step session (caller drives, `quit` closes everything):**
```ruby
browser.navigate_to(url)              # opens fresh page, navigates
browser.click(selector, text: nil)    # clicks first visible match; returns true/false
browser.fill_field(selector, value, tag, form_index: nil)  # Vue/React-compatible fill
browser.attach_file(file_input, cv_path)   # injects file via DataTransfer (cross-container safe)
browser.attempt_recaptcha_refresh     # best-effort reCAPTCHA v3 token refresh; never raises
browser.wait_for_idle(timeout: 10)
browser.body
browser.screenshot                    # returns binary PNG
browser.quit                          # called in operation cleanup
```

Operations that use the multi-step API: `Apply::Operation::Ai::FetchExternalForm` (uses self-contained), `Apply::Operation::SendApply::Browser` (uses multi-step).

## Apply::Operation::Base pipeline API

Every apply pipeline step inherits `Apply::Operation::Base` and defines:

```ruby
def start_status = :my_status          # set on apply before run!
def error_status = :failed_my_status   # set on apply if run! raises
def success_status                     # optional — set on apply after run! returns; nil skips
  :completed
end
```

`perform!` flow:
1. Skip if `apply.error.present?` (pipeline already failed upstream)
2. `apply.update!(status: start_status)` + broadcast
3. `run!(apply:, handler:, **options)`
4. If `success_status` is non-nil: `apply.update!(status: success_status)` + broadcast
5. On any raise: `apply.update!(status: error_status, error: e.message)` + broadcast + re-raise

`run!` should only raise on failure — never call `apply.update!` or broadcast from within `run!` when `success_status` is defined.
