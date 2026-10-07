# Apply Handlers

Handlers live in `app/concepts/apply/handler/`. Each job board has its own handler that owns the complete apply pipeline for that source.

## Resolution

The handler is resolved from the source's configured scraper class name:

```ruby
# Apply::Handler::Base
def self.for(apply)
  scraper_name = apply.source_profile.source.scraper.demodulize  # "Djinni" or "Dou"
  "Apply::Handler::#{scraper_name}".constantize.new(apply:)
end
```

Resolved once in `Apply::Job::Apply`:

```ruby
class Apply::Job::Apply < ApplicationJob
  queue_as :apply
  limits_concurrency to: 1, key: ->(apply_id) { "apply:#{apply_id}" }, duration: 45.minutes

  def perform(apply_id)
    apply = Apply.find(apply_id)
    Apply::Handler::Base.for(apply).call
  rescue ActiveRecord::RecordNotFound
    nil
  rescue ApplyMate::Client::Browser::PoolBusy
    raise
  rescue StandardError => e
    Apply::Operation::Engine::Lifecycle::HaltUnowned.call(apply_id:, code: :unexpected_error, detail: e.class.name)
    raise
  end
end
```

`limits_concurrency` guards against a duplicate run of the same Apply; the number of concurrent browsers is capped by the apply worker's threads (`APPLY_SLOTS`). Run ownership, states and failure recording are described in `.ai/docs/apply_engine.md`.

A step must never rescue `ApplyMate::Client::Browser::PoolBusy` (nor `StandardError` around a `Session.open`): the Runner turns it into `waiting_capacity` and the job's `retry_on` retries it (`apply_engine.md`, exit table). Swallowing it would turn "no free browser" into a failed step.

## Pipeline DSL

Handlers declare steps with `add_step`. Each step is an `Apply::Operation::Base` subclass that declares its `stage`:

```ruby
add_step OperationClass
add_step OperationClass, if: ->(ctx) { ctx.apply.some_condition? }
add_step OperationClass, prompt_class: SomePrompt, schema_class: SomeSchema
```

- Each `add_step` becomes an `Apply::Handler::Base::Step` (`operation`, `condition`, `options`, `position`); `Step#key` is the operation's `stage`, and `steps` keeps the declaration order
- `if:` — lambda called with the run's `Apply::Operation::Engine::Context` (`ctx.apply`, `ctx.attempt`); the step is skipped (no `apply_steps` row) if it returns falsy
- Extra keyword arguments (`prompt_class:`, `schema_class:`, etc.) are forwarded as `**options` into the operation's `run!` method

## The Runner wraps the steps

`Apply::Handler::Base#call` hands the handler to the Runner (`Apply::Operation::Engine::Run`), which owns the run:
it starts it (`StartContext`: state `running`, `attempt + 1`, fresh `run_token`), runs the heartbeat, and for each
applicable step writes `applies.stage`, creates one `apply_steps` row, broadcasts, and calls
`operation.call(ctx:, handler:, **options)`. The outcome is recorded once, by the Runner:

- every step succeeded → `Lifecycle::Finish`: `completed`, `submitted_at`, `submitted_via: 'engine'`, `stage: nil`;
- a step raised `Apply::Operation::Engine::Halt` → `Lifecycle::RecordHalt` with the halt's state (and the claim
  rule, below); any other exception is mapped to a code (`invalid_ai_output`, `invalid_record`, `unexpected_error`).

States, codes, fencing and timing: `.ai/docs/apply_engine.md`.

## Step contract

```ruby
class Apply::Operation::FetchDetails < Apply::Operation::Base
  stage :fetch_details # applies.stage while it runs; the apply_steps key

  private

  def run!(apply:, handler:, ctx:, **)
    # ...
    halt!(:no_application_path, detail: 'why, for admins') if something_missing
  end

  def cleanup; end # always runs (tempfiles; browser sessions close in their own block); its own errors are logged, never raised
end
```

- `stage` is mandatory: `Step#key` raises `NotImplementedError` for an operation without one.
- `Apply::Operation::Base#perform!(ctx:, handler: nil, **options)` calls `skip_authorize`, sets `model = ctx.apply`
  and calls `run!(apply: ctx.apply, handler:, ctx:, **options)`; declare only the keywords you use and keep `**`.
- `run!` may persist step data (`apply.update!(form_data: …)`, `apply.cv.attach`, `vacancy.update!`). It never
  writes `state` / `stage` / `failure` and never broadcasts `Apply::TurboHandler::StatusUpdate`.
- To stop the run with a specific outcome call `halt!(code, detail:, definitive: false)` (raises
  `Apply::Operation::Engine::Halt`; unknown codes raise `ArgumentError`). `detail` is admin-only and redacted before
  it is stored; users see `apply.failure.<code>` only.
- `cleanup` runs inside the step, i.e. **before** the Runner records the outcome: at that moment the apply is still
  `running` in this step's stage (see `GeneratePdfCv` below).

## Stages and Halt codes of the current steps

| Step | `stage` | Halts |
|---|---|---|
| `CheckApplyable` | `check_applyable` | no reply button → `applyble: false`, `no_application_path` (detail `no reply button`) |
| `FetchApplyType` | `fetch_apply_type` | scraper returns `nil` → `applyble: false`, `no_application_path` |
| `FetchDetails` | `fetch_details` | — |
| `FetchInternalForm` | `fetch_form` | blank vacancy page → `not_a_form` (detail `empty vacancy page`) |
| `Ai::FetchExternalForm` | `fetch_form` | no `vacancy.external_url` → `no_application_path`; AI finds no form / trigger / form URL → `not_a_form`; empty rendered page, trigger not on the page (`TargetNotFound`) or revealing nothing, empty form URL page → `target_not_found`; an AI `form_url` (resolved against the page URL) on a non-public address → `ApplyMate::Net::UnsafeUrlError` from `ResolvePublicAddress` → `private_address` (`unsupported`, Runner mapping). Renders in a `Session` (`humanize: false`); the trigger click is `click(Target.css(ai_selector))` → `settle(:click)` → `ready?(form, timeout: 10)` (a `false` is ignored: the AI re-check decides); the AI selector is stored as `trigger_selector` as-is |
| `Ai::FillForm` | `fill_form` | AI returned an empty payload → `invalid_ai_output` |
| `Ai::GeneratePdfCv` | `generate_cv` | — (must equal the stage `Apply.with_cv_or_generating_cv` lists as a CV placeholder) |
| `SendApply::Http` | `submit` | see "Submit and the claim" |
| `SendApply::Browser` | `submit` | see "Submit and the claim" |

Exceptions without a `halt!` keep their Runner mapping: `FormExtractor`'s "No form found" is `unexpected_error`,
an AI `EmptyResponse` / `InvalidResponse` is `invalid_ai_output`.

`Ai::GeneratePdfCv` broadcasts `VacancyCv::TurboHandler::Index.broadcast` when it starts (the placeholder appears) and
`broadcast_row(apply, leaving: !apply.cv.attached?)` in `cleanup`: the placeholder becomes the CV, or — when the step
failed — is removed explicitly, because the Runner clears `applies.stage` only after the cleanup.

## Submit and the claim

Both submit steps take the claim with `Apply::Operation::Engine::ClaimSubmit.call(ctx:)` after everything that can
fail without side effects and immediately before the irreversible action. After the claim every halt lands in
`submit_unverified` (claim rule, `apply_engine.md`), except `session_expired` / `validation_rejected` raised with
`definitive: true`, which release the claim.

**`SendApply::Http`** — cookies, headers and `handler.build_payload(apply)` (CV download) first, then the claim, then
`client.post_multipart`:

| Response | Outcome |
|---|---|
| 2xx, or 301/302/303 elsewhere | returns → `completed` |
| `nil` | `outcome_unknown` (`no response`) → `submit_unverified` |
| redirect matching `/login`, `/signin`, `/auth` | `session_expired`, `definitive: true` → claim released, `needs_human` ("refresh your session") |
| redirect to the vacancy page without `applied` in the query | `outcome_unknown` (detail: location) → `submit_unverified` |
| any other status | `outcome_unknown` (`HTTP <status>`) → `submit_unverified` |

**`SendApply::Browser`** — one `Session.open(..., humanize: true)` (the only humanized lease, design §19): `goto`, the
trigger (`click(Target.css(trigger))`, `TargetNotFound` → `target_not_found`, no claim; then `settle(:click)` and
`ready?(Target.css('form'), timeout: 10)`), fill, CV upload, the submit-button check
`present?(submit_target, visibility: :required)` (missing → `target_not_found`, no claim, `failed`), claim, `click`
(a `TargetNotFound` now → `target_not_found` after the claim → `submit_unverified`), `settle(:submit)`, full-page
screenshot and HTML; the lease is released before the verdict call (`CheckSubmitResult`).

- **Fill:** every `filled_inputs` entry with a value except `file` / `hidden` / `checkbox` / `radio` (hidden inputs
  belong to the page; option widgets come with phase 3). Target strategies: the stored selector, then
  `FORM_CONTROLS_CSS` with `nth: form_index` (position). `select` tags → `session.select(value:)`, the rest
  `session.fill`; then `settle(:key)` and a read-back through `probe(:read_value)`: a value that does not read back
  (whitespace-squished compare) → `required_field_unfillable` before the claim. A field that is not on the page →
  `target_not_found` (Runner mapping), also before the claim.
- **CV:** `upload` to the file input (stored selector, `input[type="file"]`, position) + `settle(:file)`.
- **Submit target:** strategies `{css: submit_selector, has_text: submit_text}` then `{css: submit_selector}`; each
  must match exactly one visible element (`Locate`).
- No reCAPTCHA token refresh: input is trusted (Camoufox) and nothing injects tokens.

| Verdict | Outcome |
|---|---|
| `success: true` | returns → `completed` |
| `success: false` | `validation_rejected` (detail: reason), **not** definitive → `submit_unverified`, claim kept |
| no text (`EmptyResponse`) or unparseable (`InvalidResponse`) | not rescued in the step: the Runner maps it to `invalid_ai_output` (`Run::ERROR_CODES`), the claim rule makes it `submit_unverified` |

An AI verdict alone never releases a claim (design §11.4). A claimed apply is not startable again (`StartContext`
only starts `queued` / `waiting_capacity` / stale `running`), so a second run never submits twice; the user resolves
`submit_unverified` through MarkOutcome.

## Djinni Handler

Djinni has only the in-platform apply flow (`fetch_apply_type` always returns `internal`):

```ruby
class Apply::Handler::Djinni < Apply::Handler::Base
  add_step Apply::Operation::CheckApplyable
  add_step Apply::Operation::FetchApplyType
  add_step Apply::Operation::FetchDetails
  add_step Apply::Operation::FetchInternalForm
  add_step Apply::Operation::Ai::FillForm, prompt_class: Apply::Ai::Prompt::FillForm, schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv, prompt_class: Apply::Ai::Prompt::GenerateCv, schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::SendApply::Http
end
```

## DOU Handler

DOU supports both internal (in-platform) and external (company site via browser) apply flows, distinguished by `apply.apply_type`:

```ruby
class Apply::Handler::Dou < Apply::Handler::Base
  add_step Apply::Operation::CheckApplyable
  add_step Apply::Operation::FetchApplyType
  add_step Apply::Operation::Ai::FetchExternalForm, if: ->(ctx) { ctx.apply.external? }
  add_step Apply::Operation::FetchInternalForm,      if: ->(ctx) { ctx.apply.internal? }
  add_step Apply::Operation::Ai::FillForm, prompt_class: Apply::Ai::Prompt::FillForm, schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv, prompt_class: Apply::Ai::Prompt::GenerateCv, schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::SendApply::Browser, if: ->(ctx) { ctx.apply.external? }
  add_step Apply::Operation::SendApply::Http, if: ->(ctx) { ctx.apply.internal? }
end
```

## CheckApplyable vs FetchApplyType

Both handlers run `CheckApplyable` first and `FetchApplyType` second:

- `CheckApplyable` calls `scraper.fetch_applyble(url, session_id:)` and stores `apply.applyble`; when the page has no reply button it stores `applyble: false` and halts with `no_application_path` (→ `unsupported`).
- `FetchApplyType` calls `scraper.fetch_apply_type(url, session_id:)`, stores `apply_type` (and `applyble: true`), and copies an `external_url` onto the vacancy; a `nil` result stores `applyble: false` and halts with `no_application_path`.

On DOU both scraper methods GET the same vacancy page (two requests through `ImpersonateHttp`, each with `session_headers(session_id)`), and the external/internal steps are gated on the type `FetchApplyType` stored. On Djinni `fetch_apply_type` makes no request, so `CheckApplyable` is the only check that the reply button exists.

## Handler::Base shared helpers

These are public methods available to operations via `handler:`:

| Method                 | Purpose                                                                             |
| ---------------------- | ----------------------------------------------------------------------------------- |
| `cv_filename`          | Returns the PDF filename derived from the user profile name                         |
| `build_payload(apply)` | Builds the multipart form payload from `filled_inputs`, attaches CV file if present |

Source-specific values an operation needs come from the scraper or the source, not from the handler: `scraper.session_headers(session_id)` is the authenticated Cookie header (`FetchInternalForm`, and the scrapers' own `fetch_applyble` / `fetch_apply_type`), `scraper.form_selector` picks the apply form, and `Source#session_cookie_name` names the session cookie in `SendApply::Http`'s cookie jar (the profile's session wins over an anonymous captured one).

## Adding a new source

1. Create `app/concepts/apply/handler/my_site.rb` inheriting `Apply::Handler::Base`
2. Declare the pipeline with `add_step` — add `if:` for conditional steps
3. Pass `prompt_class:` / `schema_class:` inline on any AI steps
4. Add the scraper class to `Source::SCRAPERS` (see `.ai/docs/scrapers.md`)
5. No changes needed to the job or any shared operation
