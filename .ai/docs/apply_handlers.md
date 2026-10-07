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
  end
end
```

`limits_concurrency` guards against a duplicate run of the same Apply; the number of concurrent browsers is capped by the apply worker's threads (`APPLY_SLOTS`).

## Pipeline DSL

Handlers declare steps with `add_step`. Each step maps to an `Apply::Operation::Base` subclass:

```ruby
add_step OperationClass
add_step OperationClass, execute_condition: ->(apply) { apply.some_condition? }
add_step OperationClass, prompt_class: SomePrompt, schema_class: SomeSchema
```

- `execute_condition:` — lambda called with `apply`; step is skipped if it returns falsy
- Extra keyword arguments (`prompt_class:`, `schema_class:`, etc.) are forwarded as `**options` into the operation's `run!` method

`call` iterates steps in order. A failing step stores its `error_status` and `error` on the apply and re-raises (`Apply::Operation::Base#perform!`), which aborts `call` and fails `Apply::Job::Apply`. The `return if apply.error.present?` guard at the top of `perform!` is only a backstop for the one exception `ApplyMate::Operation::Base#call` swallows (`ActiveRecord::RecordInvalid`), after which `call` would otherwise move on to the next step.

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
  add_step Apply::Operation::Ai::FetchExternalForm, execute_condition: ->(apply) { apply.external? }
  add_step Apply::Operation::FetchInternalForm,      execute_condition: ->(apply) { apply.internal? }
  add_step Apply::Operation::Ai::FillForm, prompt_class: Apply::Ai::Prompt::FillForm, schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv, prompt_class: Apply::Ai::Prompt::GenerateCv, schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::SendApply::Browser, execute_condition: ->(apply) { apply.external? }
  add_step Apply::Operation::SendApply::Http, execute_condition: ->(apply) { apply.internal? }
end
```

## CheckApplyable vs FetchApplyType

Both handlers run `CheckApplyable` first and `FetchApplyType` second:

- `CheckApplyable` calls `scraper.fetch_applyble(url, session_id:)` and stores `apply.applyble`; it raises `Vacancy is not applyable` (after `applyble: false`) when the page has no reply button.
- `FetchApplyType` calls `scraper.fetch_apply_type(url, session_id:)`, stores `apply_type` (and `applyble: true`), and copies an `external_url` onto the vacancy; a `nil` result stores `applyble: false` and raises.

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
2. Declare the pipeline with `add_step` — add `execute_condition:` for conditional steps
3. Pass `prompt_class:` / `schema_class:` inline on any AI steps
4. Add the scraper class to `Source::SCRAPERS` (see `.ai/docs/scrapers.md`)
5. No changes needed to the job or any shared operation
