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
  def perform(apply_id)
    apply = Apply.find(apply_id)
    Apply::Handler::Base.for(apply).call
  end
end
```

## Pipeline DSL

Handlers declare steps with `add_step`. Each step maps to an `Apply::Operation::Base` subclass:

```ruby
add_step OperationClass
add_step OperationClass, execute_condition: ->(apply) { apply.some_condition? }
add_step OperationClass, prompt_class: SomePrompt, schema_class: SomeSchema
```

- `execute_condition:` — lambda called with `apply`; step is skipped if it returns falsy
- Extra keyword arguments (`prompt_class:`, `schema_class:`, etc.) are forwarded as `**options` into the operation's `run!` method

`call` iterates steps in order; if a step sets `apply.error`, subsequent steps are skipped (handled by `Apply::Operation::Base#perform!`).

## Djinni Handler

```ruby
class Apply::Handler::Djinni < Apply::Handler::Base
  add_step Apply::Operation::CheckApplyable
  add_step Apply::Operation::FetchApplyType
  add_step Apply::Operation::FetchDetails
  add_step Apply::Operation::FetchInternalForm
  add_step Apply::Operation::Ai::FillForm,
           prompt_class: Apply::Ai::Prompt::FillForm,
           schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv,
           prompt_class: Apply::Ai::Prompt::GenerateCv,
           schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::SendApply::Http
end
```

## DOU Handler

DOU supports both internal (in-platform) and external (company site via browser) apply flows, distinguished by `apply.apply_type`:

```ruby
class Apply::Handler::Dou < Apply::Handler::Base
  add_step Apply::Operation::FetchApplyType   # also sets apply.applyble
  add_step Apply::Operation::FetchDetails
  add_step Apply::Operation::Ai::FetchExternalForm,
           execute_condition: ->(apply) { apply.external? }
  add_step Apply::Operation::FetchInternalForm,
           execute_condition: ->(apply) { apply.internal? }
  add_step Apply::Operation::Ai::FillForm,
           prompt_class: Apply::Ai::Prompt::FillForm,
           schema_class: Apply::Ai::ResponseSchema::FillForm
  add_step Apply::Operation::Ai::GeneratePdfCv,
           prompt_class: Apply::Ai::Prompt::GenerateCv,
           schema_class: Apply::Ai::ResponseSchema::GenerateCv
  add_step Apply::Operation::SendApply::Browser,
           execute_condition: ->(apply) { apply.external? }
  add_step Apply::Operation::SendApply::Http,
           execute_condition: ->(apply) { apply.internal? }
end
```

## CheckApplyable vs FetchApplyType

`FetchApplyType` always sets `apply.applyble` as a side effect (true on success, false + raise when nil). For scrapers where `fetch_apply_type` makes an HTTP request (DOU), adding `CheckApplyable` before it wastes a redundant request to the same URL — omit it.

Only include `CheckApplyable` when the scraper's `fetch_apply_type` is lightweight and does not actually verify applicability (e.g. Djinni's implementation always returns `{ type: 'internal' }` without an HTTP call, so a separate HTTP check is needed).

## Handler::Base shared helpers

These are public methods available to operations via `handler:`:

| Method | Purpose |
|--------|---------|
| `cv_filename` | Returns the PDF filename derived from the user profile name |
| `build_payload(apply)` | Builds the multipart form payload from `filled_form_data`, attaches CV file if present |

## Adding a new source

1. Create `app/concepts/apply/handler/my_site.rb` inheriting `Apply::Handler::Base`
2. Declare the pipeline with `add_step` — add `execute_condition:` for conditional steps
3. Pass `prompt_class:` / `schema_class:` inline on any AI steps
4. Add the scraper class to `Source::SCRAPERS` (see `.ai/docs/scrapers.md`)
5. No changes needed to the job or any shared operation
