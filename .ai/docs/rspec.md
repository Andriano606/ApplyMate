# RSpec Patterns

## Shared Operation Context

All specs with `type: :operation` automatically include the `"with shared operation spec variables"` context (wired in `spec/rails_helper.rb`). This provides:

| `let`          | Default                                       | Description                    |
| -------------- | --------------------------------------------- | ------------------------------ |
| `operation`    | `described_class.new(params:, current_user:)` | Operation instance             |
| `result`       | `operation.tap(&:call).result`                | Result after calling           |
| `model`        | `result.model`                                | Shorthand for the result model |
| `params`       | `{}`                                          | Override per example/context   |
| `current_user` | `nil`                                         | Override with a real user      |

Override with `let(:params) { { ... } }` or `let(:current_user) { create(:user) }`.

```ruby
RSpec.describe SourceProfile::Operation::Index, type: :operation do
  let(:current_user) { create(:user) }

  it "returns source profiles scoped to user" do
    expect(result).to be_success
    expect(model).to all(satisfy { |sp| sp.user == current_user })
  end

  context "with pagination" do
    let(:params) { { page: "2" } }

    it "returns page 2" do
      expect(model.current_page).to eq(2)
    end
  end
end
```

## Elasticsearch Specs

`after_commit` callbacks do not fire inside RSpec transactions, so Elasticsearch callbacks never index documents automatically. You must manually index and refresh.

Include the `"with elasticsearch index"` context (defined in `spec/support/elasticsearch.rb`) which creates and drops the index around the suite:

```ruby
RSpec.describe Vacancy::Operation::Index, type: :operation do
  include_context "with elasticsearch index"

  # Clean ES between examples (AR records are rolled back by transactions, ES is not)
  after do
    Elasticsearch::Model.client.delete_by_query(
      index: Vacancy.index_name,
      body:  { query: { match_all: {} } },
      refresh: true
    )
  end

  let(:source) { create(:source) }
  let!(:vacancy) { create(:vacancy, source:, title: "Rails Developer") }

  before do
    vacancy.__elasticsearch__.index_document
    Vacancy.__elasticsearch__.refresh_index!
  end

  it "finds by title" do
    expect(result).to be_success
    expect(model.map(&:id)).to include(vacancy.id)
  end
end
```

**Rule:** always call `refresh_index!` after indexing — without it the search won't see the new documents.

## Job Specs

The `rails_helper.rb` swaps the queue adapter to `:test` for `type: :job` specs:

```ruby
RSpec.describe Apply::Job::Apply, type: :job do
  it "enqueues without error" do
    expect { described_class.perform_later(apply.id) }
      .to have_enqueued_job(described_class)
  end

  it "runs inline" do
    perform_enqueued_jobs { described_class.perform_now(apply.id) }
    expect(apply.reload).to be_completed
  end
end
```

## Factories

Factories live in `spec/factories/`. ActiveStorage attachments require an `after(:build)` hook:

```ruby
FactoryBot.define do
  factory :source do
    name     { "Test Source" }
    base_url { "https://example.com" }
    scraper  { "ApplyMate::Scraper::Djinni" }
    # no `client` — Source#build_scraper builds the scraper class's http_client_class

    after(:build) do |source|
      source.logo.attach(
        io:           Rails.root.join("spec/fixtures/files/photo.jpg").open,
        filename:     "logo.jpg",
        content_type: "image/jpeg"
      )
    end
  end
end
```

**Stale factory attributes cause `NoMethodError: undefined method 'x=' for an instance of Model`** — the column was dropped but the factory still sets it. Fix: remove the attribute from the factory.

**Check enum values before using them in specs** — read `Apply.states` / `ApplyStep.states` (or the model's `enum` declaration) instead of guessing; an invalid symbol raises `ArgumentError: 'x' is not a valid state`. For `Apply` prefer the factory traits `:running`, `:completed`, `:failed`, `:claimed`, `:needs_human`. A user has at most one active apply (`queued running waiting_capacity needs_review needs_human`) per vacancy (`index_applies_one_active_per_vacancy`): a second apply for the same user + vacancy in a spec must be in a finished state (e.g. `:completed`, `:failed`).

Use `sequence` for columns that must be unique:

```ruby
factory :vacancy do
  sequence(:external_id) { |n| "ext-#{n}" }
  title { "Ruby Developer" }
end
```

## Testing Apply Pipeline Operations

`Apply::Operation::*` steps run inside a run of the engine (see `.ai/docs/apply_handlers.md`), so a spec gives them a
real run context. `engine_context(apply)` (`spec/support/apply_engine.rb`) is a real `StartContext`: the apply must be
startable (`queued`, the default state — the shared contexts create it that way) and becomes `running`, attempt 1:

```ruby
described_class.call(ctx: engine_context(apply), handler:, **options)

described_class.call(
  ctx:           engine_context(apply),
  prompt_class:  Apply::Ai::Prompt::FillForm,      # add_step options are passed explicitly
  schema_class:  Apply::Ai::ResponseSchema::FillForm
)
```

Called directly, a step only does its own work: success is `be_success` plus the data it stored
(`apply.reload.inputs`, `cv`, …); an outcome is the `Apply::Operation::Engine::Halt` it raises:

```ruby
expect { run_operation }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
  expect(halt).to have_attributes(code: :outcome_unknown, detail: 'HTTP 500')
}
```

Lifecycle state, `failure`, the claim and `apply_steps` rows are written by the Runner. To assert them, run the step as
the only step of a real run with `run_engine_step(apply, described_class, **options)`, which returns the reloaded
apply (a block receives the handler instance, e.g. to stub `build_payload`), or run the whole handler
(`Apply::Handler::Dou.new(apply:).call`):

```ruby
run_engine_step(apply, described_class) { |handler| allow(handler).to receive(:build_payload).and_return(payload) }

expect(apply).to be_submit_unverified
expect(apply.submit_claimed_at).to be_present
expect(apply.failure).to include('code' => 'outcome_unknown', 'stage' => 'submit', 'after_claim' => true)
expect(apply.apply_steps.sole).to have_attributes(stage: 'submit', state: 'failed', error_code: 'outcome_unknown')
```

`failure` is a jsonb hash with string keys; `apply.apply_steps.chronological` lists the step rows in run order.
To prove the claim is taken before the irreversible action, read `Apply.find(apply.id).submit_claimed_at` inside the
stubbed `post_multipart` / submit `click`.

Runner and lifecycle specs (`spec/concepts/apply/operation/engine/`) use the fake two-step pipeline in
`spec/support/apply_engine_fakes.rb` (see `.ai/docs/apply_engine.md`, "Specs"). Browser steps run against a
`FakeSession` (below); the real browser layer has its own `:browser` specs.

Pre-populate `apply` with jsonb_accessor attributes using `update!`:

```ruby
before do
  apply.update!(
    external_url:    'https://example.com/apply',
    submit_selector: 'button[type="submit"].btn',
    submit_text:     'Apply Now',
    filled_inputs:   [{ 'name' => 'email', 'selector' => '[name="email"]',
                        'tag' => 'input', 'type' => 'email',
                        'form_index' => 0, 'value' => 'dev@example.com' }]
  )
  apply.cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'CV.pdf',
                  content_type: 'application/pdf')
end
```

## FakeSession (browser steps)

Steps that open an `ApplyMate::Client::Browser::Session` (`Ai::FetchExternalForm`, `SendApply::Browser`) are specced
against `FakeSession` (`spec/support/fake_session.rb`): same public methods and parameters as `Session` (enforced by
`spec/concepts/apply_mate/client/browser/session_contract_spec.rb`), no browserd.

```ruby
let(:session) { FakeSession.new(html: page_html, final_url: url) } # cookies: '', read_values: {}, missing: []
before { stub_browser_session(session) } # Session.open yields it, returns the block value, records the kwargs
```

| Knob / reader | Effect |
|---|---|
| `html:` / `final_url:` / `cookies:` | what `html`, `current_url`, `cookies` (and `goto`'s `NavResult`) return |
| `missing: [css, …]` | a target whose **first** strategy's css is listed is not on the page: `click` / `fill` / `select` / `upload` / `probe` / … raise `TargetNotFound`, `present?` / `ready?` return `false` |
| `read_values: { css => value }` | `probe(:read_value, target)['value']` for that target; otherwise it echoes the last `fill` / `select` into the same target |
| `on(:click) { \|target\| … }` | hook run before a call is handled: read the DB mid-step or `raise` (e.g. a button that vanishes after the claim) |
| `calls` / `calls_of(:click)` | every call as `[method, *args, kwargs]` (kwargs hash only when the method has any), e.g. `[:goto, url]`, `[:settle, :click]`, `[:present?, target, { visibility: :required }]` |
| `open_options` | one kwargs hash per `Session.open` (assert `humanize:` and `deadline <= ctx.deadline_at`) |

```ruby
expect(session.calls).to include([ :goto, HoneytechDou::DOU_REDIRECT ])
expect(session.calls_of(:click).map(&:first)).to eq([ ApplyMate::Client::Browser::Target.css('#trigger'), submit_target ])
expect(session.open_options.sole).to include(humanize: true)

claimed_at_click = nil
session.on(:click) { claimed_at_click = Apply.find(apply.id).submit_claimed_at } # claim taken before the click
```

`spec/support/shared_contexts/honeytech_dou.rb` wires one `FakeSession` (`let(:session)`) for both browser steps of
the DOU external flow; override `let(:session)` in a context to script `missing:` / `read_values:`.

The production path of the same steps is covered by `spec/concepts/apply/operation/send_apply/browser_browserd_spec.rb`
(`:browser`): FetchExternalForm + SendApply::Browser on the real Session against `FixtureSite` (form page, trigger
page, a `maxlength` read-back mismatch), with only Gemini stubbed (`allow(Session).to receive(:open).and_call_original`
undoes the shared context's FakeSession).

## Browser specs (`:browser`)

Examples tagged `:browser` drive the **real** `ApplyMate::Client::Browser::Driver::Playwright` (Camoufox via
browserd) against static fixture pages. Use them for anything the browser layer does (Session, Locate, settle, probes,
widgets); unit specs with fakes cover the pure loops (`WaitQuiet`, `WaitPastCloudflare`, `NetTracker`).

- **Tag semantics** (`spec/support/browser_tag.rb`): `:browser` examples are excluded unless `BROWSERD_URL` is set, so
  the production driver is tested wherever a browserd is available (dev compose, the CI `browser_specs` job). Nothing in
  `app/` reads this switch. `BROWSERD_TOKEN` must equal the container's token.
- **Where they run:** against the test-only compose service `browserd-test` (`http://localhost:9310`, 3 slots, may
  reach the docker host), never the dev `browserd` on `:9300`. Conductor workspaces have
  `BROWSERD_URL=http://localhost:9310`/`BROWSERD_TOKEN` in `.env.test.local` (`bin/conductor/setup.rb`), so a plain
  `bundle exec rspec` includes them and fails loudly if `browserd-test` is down; `BROWSERD_URL= bundle exec rspec` excludes them. In CI the `test` job excludes them and the `browser_specs`
  job builds `docker/browserd`, starts it with `docker run` and runs `bundle exec rspec --tag browser`
  (`.ai/docs/browser.md` "Dev / CI / staging wiring").
- **`FixtureSite`** (`spec/support/fixture_site.rb`, pages in `spec/support/fixture_site/pages/`): an in-process Puma
  bound to `0.0.0.0` on a free port, started in `before(:suite)` only when a `:browser` example is selected.
  `FixtureSite.url('/form.html')` = `http://#{FIXTURE_SITE_HOST}:<port>/form.html` (`FIXTURE_SITE_HOST` defaults to
  `host.docker.internal`, which the browserd container resolves to the docker host; `browserd-test`'s and CI's
  `EGRESS_ALLOW_RANGES=host.docker.internal` lets smokescreen reach exactly that one address). Routes: `GET /<page>.html` and `/slow-reveal.js` (form.html sets `fixture_session=abc123`),
  `POST /submit` → 200 "Thank you for applying".

  | Page | Contents |
  |---|---|
  | `form.html` | `form#apply`: text (`#full_name`, `maxlength=40`), email (`data-qa`), textarea, native select, checkbox, radio pair, styled toggle (`#remote` hidden, `#remote-root` visible), visually hidden (clip 1px) `#cv` file input with a `label.dropzone`, "Submit application"; plus a newsletter form, so `button[type=submit]` matches twice |
  | `trigger.html` + `slow-reveal.js` | "Apply now" button that injects `form#late-form` 1.5 s after the click |
  | `iframe.html` | `form.html` in `iframe#embed` (`name="embedded-form"`) |
  | `challenge.html` | "Just a moment..." title + `cf-chl-` marker, replaced by real content after 2 s |
  | `multi.html` | two identical `button.apply` |
  | `responsive.html` | two `input[name=email]`: `#email_mobile` hidden (`display: none`), `#email_desktop` visible (hidden-duplicate ambiguity) |

- **PublicAddressGuard seam:** the fixture host is a private address, so `browser_tag.rb` wraps
  `ApplyMate::Net::Operation::ResolvePublicAddress.call` (`and_wrap_original`, in a `before(:each, browser: true)`)
  to return a `Resolution` for URLs on `FixtureSite.host`; every other URL runs the real operation (so
  `goto('http://127.0.0.1:1/')` still raises `UnsafeUrlError`). There is no production flag for this. Navigate in a
  `before` block (or the example), not in an `around` hook: `around` runs before the seam is installed.
- **Leases:** every `Session.open` launches a fresh Camoufox (~2–5 s). Use an owner under
  `Browserd.owner_prefix` (hostname + workspace dir + env, so parallel workspaces never sweep each other) and release
  what you acquire (`Session.open` does it in `ensure`). `browserd-test` is shared by every workspace: assert on your
  own owner's leases (`ReleaseOrphanLeases.call(owner_prefix: owner).model == 0`), never on the global `/health`
  `leases` count. To make `PoolBusy` fast, stub `ApplyMate::Client::Browser::Clock.sleep_ms` (the Retry-After waits).

```ruby
RSpec.describe ApplyMate::Client::Browser::Session, :browser do
  it 'fills and reads back' do
    described_class.open(deadline: 2.minutes.from_now, owner: "#{ApplyMate::Client::Browser::Browserd.owner_prefix}spec") do |session|
      session.goto(FixtureSite.url('/form.html'))
      session.fill(ApplyMate::Client::Browser::Target.css('#email'), 'jane@example.com')

      expect(session.probe(:read_value, ApplyMate::Client::Browser::Target.css('#email'))['value']).to eq('jane@example.com')
    end
  end
end
```

Run locally (first build downloads ~1.3 GB):

```bash
docker compose up -d browserd-test
BROWSERD_URL=http://localhost:9310 BROWSERD_TOKEN=dev-browserd-token bundle exec rspec --tag browser
```

`spec/config/browserd_image_tag_spec.rb` (no browserd needed) keeps the image tag triple in `docker/browserd`,
`docker-compose.yml`, `config/deploy.staging.yml` and `Gemfile.lock` consistent.

## Spec File Naming Convention

Spec files must be named after the **class under test**, not after the company/fixture. The path mirrors the class hierarchy:

| Class                                 | Spec file                                                   |
| ------------------------------------- | ----------------------------------------------------------- |
| `Apply::Operation::FetchInternalForm` | `spec/concepts/apply/operation/fetch_internal_form_spec.rb` |
| `Apply::Operation::SendApply::Http`   | `spec/concepts/apply/operation/send_apply/http_spec.rb`     |
| `Apply::Handler::Dou`                 | `spec/concepts/apply/handler/dou_spec.rb`                   |
| `Apply::Handler::Djinni`              | `spec/concepts/apply/handler/djinni_spec.rb`                |

When multiple company fixtures test the **same class**, wrap each in a `context` block inside one file — do not create `honeytech_spec.rb`, `coidea_spec.rb`, etc. If the file already has `include_context` at the top-level `RSpec.describe`, move the existing content into a context block and keep shared helpers (e.g. `http_response`) at the describe level:

```ruby
RSpec.describe Apply::Operation::FetchInternalForm do
  context 'Djinni internal apply (Art of Spin)' do
    include_context 'art of spin djinni'
    # stubs + examples
  end

  context 'DOU internal apply (Coidea Agency)' do
    include_context 'coidea dou'
    # stubs + examples
  end
end
```

## Shared Contexts for Multi-Operation Specs

When testing several operations against the same company fixture, put common setup in a named shared context. Keep constants in a companion module to avoid Ruby's constant-hoisting problem (constants inside `RSpec.describe` blocks are silently promoted to `Object` and clash across files):

```ruby
# spec/support/shared_contexts/honeytech_dou.rb
module HoneytechDou
  VACANCY_URL  = 'https://jobs.dou.ua/companies/honeytech/vacancies/354709/'
  DOU_REDIRECT = 'https://dou.ua/goto/vacancy/?id=354709'
end

RSpec.shared_context 'honeytech dou' do
  let(:vacancy_external_url) { nil }          # override per spec to pre-set external_url
  let(:vacancy) { create(:vacancy, external_url: vacancy_external_url, ...) }

  # Canned AI responses reused across specs — gemini_json_response comes from spec/support/ai_responses.rb
  let(:gemini_check_form_page)     { gemini_json_response('{"has_form":true,...}') }
  let(:gemini_check_submit_result) { gemini_json_response('{"success":true,...}') }

  # Canonical filled inputs for this company — reuse in FillForm / SendApply specs
  let(:filled_inputs) { [{ 'name' => 'email', 'value' => 'dev@example.com', ... }] }

  # Pre-AI state: same fields with blank values (input to FillForm)
  let(:raw_inputs) { filled_inputs.map { |i| i.merge('value' => '') } }
end
```

Each spec `include_context 'honeytech dou'` and adds only what it owns — its HTTP stubs and AI response sequence.

**Always define `filled_inputs` and `raw_inputs` in every shared context**, even if the first spec written doesn't use them. `SendApply` and `FillForm` specs will need them, and omitting them forces a retroactive edit. `raw_inputs` is always derived:

```ruby
let(:raw_inputs) { filled_inputs.map { |i| i.merge('value' => '') } }
```

Include only the fields relevant to filling and submission — hidden/checkbox ancillaries (e.g. `save_msg_template`) can be omitted.

**Full-pipeline handler spec** stubs all four Gemini calls in order; uses shared `let`s for first and last:

```ruby
stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
  .to_return(gemini_check_form_page, gemini_fill_form, gemini_generate_cv, gemini_check_submit_result)
```

**Single-operation spec** stubs only its one call:

```ruby
stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
  .to_return(gemini_check_form_page)
```

`stub_request(...).to_return(r1, r2, r3)` serves responses in call order — each invocation consumes the next entry.

## Stubbing AI providers (WebMock)

The canned provider payloads live once in `spec/support/ai_responses.rb` (module `AiResponses`, included for every spec in `rails_helper.rb`). **Never redefine them in a shared context or spec.**

| Helper                                                        | Returns a `to_return` hash for                                                                                                                                                                                 |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gemini_json_response(text, usage: nil)`                      | Gemini `generateContent`: `candidates[0].content.parts[0].text = text`; `usage: { prompt:, candidates:, thoughts: }` adds `usageMetadata` (`promptTokenCount` / `candidatesTokenCount` / `thoughtsTokenCount`) |
| `ollama_chat_response(text, prompt_eval_count:, eval_count:)` | Ollama non-streaming `/api/chat`: `message.content = text` plus the token counts                                                                                                                               |

````ruby
stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
  .to_return(gemini_json_response('```json\n{"key":"value"}\n```'))

stub_request(:post, 'http://ollama.test:11434/api/chat')
  .to_return(ollama_chat_response('{"answer":"hi"}', prompt_eval_count: 12, eval_count: 3))
````

To assert what the client sent, capture bodies in a `with` block (see `spec/concepts/apply_mate/ai/client/gemini_spec.rb`):

```ruby
let(:sent_bodies) { [] }
stub_request(:post, endpoint).with { |req| sent_bodies << JSON.parse(req.body) }.to_return(gemini_json_response('ok'))
# …
expect(sent_bodies.sole['generation_config']).to eq('max_output_tokens' => 512)
```

`ApplyMate::Ai::Client::GeminiScraping` launches Chrome inside its private `scrape_answer`; stub `Ferrum::Browser.new` (or `scrape_answer` itself) so no browser starts.

Always suppress `Apply::TurboHandler::StatusUpdate.broadcast`, `VacancyCv::TurboHandler::Index.broadcast` and `.broadcast_row` (called by `Apply::Operation::Ai::GeneratePdfCv`), `VacancyQuestion::TurboHandler::Index.broadcast` (called by the fetch-form operations) and `Grover#to_pdf` in specs that run operations end-to-end:

```ruby
before do
  allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
  allow(VacancyCv::TurboHandler::Index).to receive(:broadcast)
  allow(VacancyCv::TurboHandler::Index).to receive(:broadcast_row)
  allow(VacancyQuestion::TurboHandler::Index).to receive(:broadcast)
  allow_any_instance_of(Grover).to receive(:to_pdf).and_return('%PDF-1.4 fake')
end
```

## Fixture HTML Files

Store real scraped pages under `spec/fixtures/files/<source>/<apply_type>/<company>/`. Use the actual production page — not a hand-crafted stub — so that CSS selectors and field names reflect reality.

```
spec/fixtures/files/
  dou/
    external/
      honeytech/
        dou_honeytech_vacancy_page.html   # DOU job listing (vacancy source page)
        honeytech_apply_page.html         # employer's external application form
    internal/
      <company>/                          # for internal DOU apply pages
```

Point `FIXTURES_DIR` in the companion module at the leaf directory so all specs in the shared context resolve paths consistently:

```ruby
module HoneytechDou
  FIXTURES_DIR = Rails.root.join('spec/fixtures/files/dou/external/honeytech')
end
```
