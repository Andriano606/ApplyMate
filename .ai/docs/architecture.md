# Apply Pipeline Architecture

## Module Boundaries

These are enforced boundaries, not guidelines. Violating them causes cross-layer coupling that breaks the separation between transport and domain logic.

| Module                                                                                               | Responsibility                                                                                                                                         | Uses                                      |
| ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| `ApplyMate::Client::AsyncHttp` (default) / `ApplyMate::Client::ImpersonateHttp` (Cloudflare sources) | Low-level HTTP transport: GET/POST/multipart, headers, timeouts, redirects, proxy. Selected per source by `Scraper.http_client_class`                  | async sockets / curl-impersonate          |
| `ApplyMate::Client::Browser::Session`                                                                | Browser transport for apply steps: a block-scoped lease on browserd (Camoufox) driven over Playwright; goto, click/fill/select/upload by `Target`, settle, read-back probes, screenshot. See `.ai/docs/browser.md` | `Driver::Playwright` → browserd |
| `ApplyMate::Net::Operation::ResolvePublicAddress`                                                    | PublicAddressGuard: every fetch of a URL that came from a page, an AI or a redirect goes through it; raises `ApplyMate::Net::UnsafeUrlError` unless http(s) and every resolved address is public | `Resolv` (`/etc/hosts` + DNS) |
| `ApplyMate::Scraper::*`                                                                              | Source-specific parsing and declarations: listing, details, applyble, apply_type, form_selector, session_cookie_name. **Never uses `Client::Browser::Session`** | the client its class declares             |
| `Apply::Handler::*`                                                                                  | Declares the pipeline via `add_step`. Owns source-specific prompt/schema class knowledge                                                               | —                                         |
| `Apply::Operation::*`                                                                                | Orchestrates one pipeline step: uses scraper + client, persists result to `apply`                                                                      | `Source#http_client` or `Client::Browser::Session` |

## Rules

**Scrapers get the client their class declares.**
`Source#build_scraper` builds whatever `Scraper.http_client_class` returns — `AsyncHttp` by default, `ImpersonateHttp` for Cloudflare-protected Dou. Scrapers only parse HTML — they never need a browser.

```ruby
def build_scraper
  klass = scraper.constantize
  klass.new(self, klass.http_client_class.new)
end
```

**Operations get their HTTP client from the source.**
Apply operations that need raw requests call `Source#http_client(**options)`, which builds the same `http_client_class` with the given options: `source.http_client(request_timeout: 30)` in `SendApply::Http`, `source.http_client` in `FetchInternalForm`. `SyncVacancies` builds `scraper_class.http_client_class.new(proxy:, request_timeout:, connect_timeout:)` for each leased proxy. The client class is not sourced from the database. The session cookie is sent through `scraper.session_headers(session_id)`, and its name comes from `Scraper.session_cookie_name` (`Source#session_cookie_name` for callers without a scraper).

**Browser is for operations, not scrapers.**
`ApplyMate::Client::Browser::Session` is used only in `Apply::Operation::*` (today `Ai::FetchExternalForm` and
`SendApply::Browser`) for pages that need real interaction. Every use is a block:
`Session.open(deadline: ctx.scope_deadline, owner: Session.owner_for(apply), humanize:, identity: apply.hashid) { |session| … }`;
the lease is released in `ensure`, so hold the block only while the page is needed (run AI calls and DB writes after
it when they do not need the page). `humanize: true` only for the submit lease. The API, leases and isolation are in
`.ai/docs/browser.md`; Ferrum remains only inside `ApplyMate::Ai::Client::GeminiScraping` (its own local Chrome).

**Handler resolution is name-based.**
The handler class is derived from the source's scraper class name:

```ruby
scraper_name = apply.source_profile.source.scraper.demodulize  # "Djinni" or "Dou"
"Apply::Handler::#{scraper_name}".constantize.new(apply:)
```

Adding a new job board requires: a new `Scraper::MySite`, a new `Handler::MySite` with `add_step` pipeline, and adding the scraper class to `Source::SCRAPERS`.

## Apply::Operation::Base pipeline API

Every apply pipeline step inherits `Apply::Operation::Base`, declares its stage and implements `run!`:

```ruby
class Apply::Operation::FetchDetails < Apply::Operation::Base
  stage :fetch_details   # applies.stage while the step runs; apply_steps key

  private

  def run!(apply:, handler:, **)
    # ...
  end
end
```

`perform!(ctx:, handler: nil, **options)` calls `skip_authorize`, sets `model = ctx.apply`, calls `run!(apply: ctx.apply, handler:, ctx:, **options)` and always runs `cleanup`. The step is called by the Runner (`Apply::Operation::Engine::Run`), which owns everything around it: `applies.stage`, the `apply_steps` row, lifecycle `state`/`failure` and the `StatusUpdate` broadcasts (see `.ai/docs/apply_engine.md`).

`run!` may persist step data with `apply.update!(form_data: …)` etc., but it must never write `state`/`stage`/`failure` or broadcast `StatusUpdate` itself. To stop the run with a specific outcome it calls `halt!(code, detail:)` (raises `Apply::Operation::Engine::Halt`; the codes of the current steps are listed in `.ai/docs/apply_handlers.md`); any other exception is recorded as `unexpected_error` (or `invalid_ai_output` / `invalid_record`). A step that submits takes the claim with `Apply::Operation::Engine::ClaimSubmit.call(ctx:)` right before the POST / click.

## Queue topology

Two Solid Queue queues exist:

| Queue     | Served by                                                  | What runs there                                         |
| --------- | ---------------------------------------------------------- | ------------------------------------------------------- |
| `default` | general worker (`SQ_THREADS`, `SQ_PROCESSES`, default 2x2) | everything that neither launches a browser nor calls AI |
| `apply`   | one apply worker, 1 process, `APPLY_SLOTS` threads         | browser and AI jobs                                     |

**Rule:** every job that may launch a browser (Grover, GeminiScraping, a future Camoufox lease) or call AI runs on `:apply` (`queue_as :apply` plus `limits_concurrency ... duration:`); everything else stays on `:default`. The jobs on `:apply` are `Apply::Job::Apply` (key `apply:<id>`, 45 min), `VacancyCv::Job::Create` (key `vacancy_cv:<id>`, 15 min) and `VacancyQuestion::Job::Create` (key `vacancy_question:<id>`, 10 min); each key prefix follows the record's own id space.

`SQ_ROLE` picks the workers a process starts. `config/queue.yml` reads it only through `Apply::Operation::AssertQueueTopology.role`, which raises `Violation` for anything but `general | apply | all` (a typo such as `generl` would otherwise render both workers and start a second apply worker beside the `apply_worker` container):

| `SQ_ROLE`       | Workers                 | Set by                                                                                     |
| --------------- | ----------------------- | ------------------------------------------------------------------------------------------ |
| `general`       | `[default]` only        | Kamal role `worker`                                                                        |
| `apply`         | `[apply]` only          | Kamal role `apply_worker`                                                                  |
| `all` (default) | both, in one supervisor | dev / Conductor (`bin/rails solid_queue:start` in `Procfile.dev` and `Procfile.conductor`) |

`APPLY_SLOTS` is the number of apply-worker threads, i.e. how many applies run at once on the host: 1 in dev, 3 in staging. It equals browserd `MAX_BROWSERS` (one Camoufox lease per running apply): staging sets both from the same ERB variable `apply_slots` in `config/deploy.staging.yml` (asserted by `spec/config/browserd_image_tag_spec.rb`), dev compose uses `MAX_BROWSERS=${APPLY_SLOTS:-1}`. `Apply::Operation::AssertQueueTopology.apply_slots` is the single reader of the variable: `config/queue.yml` calls it for the apply worker's `threads`, and the assertion compares against it. It raises `Violation` unless the value is a positive integer (default `1`).

The general worker never lists `'*'`: Solid Queue has no exclusion syntax, so `'*'` would also drain `apply` beyond `APPLY_SLOTS`. The old per-process queue-list variable is gone.

### AssertQueueTopology

`Apply::Operation::AssertQueueTopology` parses `config/queue.yml` for the current env (file only, no DB) and raises `Violation` when:

1. any worker queue contains `*`;
2. more than one worker serves `apply`;
3. the apply worker has `processes != 1` or `threads != APPLY_SLOTS`;
4. `SQ_ROLE` is `apply`/`all` and no worker serves `apply`, or `SQ_ROLE` is `general` and one does;
5. `SQ_ROLE` is not one of `general | apply | all`, or `APPLY_SLOTS` is not a positive integer (raised while rendering `queue.yml`, i.e. by Solid Queue's own config load too).

It runs from `config/initializers/solid_queue_topology.rb` (`after_initialize`), not from `SolidQueue.on_start`: solid_queue's `run_hooks_for` wraps each hook in `rescue Exception`, so a raise/`abort`/`exit` there is only logged and the supervisor keeps running. In an initializer the exception aborts boot for `bin/jobs`, puma and runner alike.

Scope: the check sees only the current process's rendered config. "Exactly one apply worker on the host" across containers rests on the Kamal roles — only `apply_worker` sets `SQ_ROLE: apply`, `worker` sets `general` — and on rule 5, which stops a misspelt role from silently serving `apply` too.
