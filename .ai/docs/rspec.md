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

Lifecycle state, `failure`, the claim and `apply_steps` rows are written by the Runner. Session scopes work the same way: declare the steps with `session_scope` on a one-off handler class, call `stub_browser_session(FakeSession.new(html:, final_url:))` first and the scope's steps get that fake as `ctx.session` (`session.open_options` records the `Session.open` kwargs: `humanize`, `identity`, `owner`, `deadline`). `ApplyEngineFakes::ScopedHandler` / `DigestOne` / `DigestTwo` cover digest skip + restore and scope atomicity (`apply_engine.md`, Specs). To assert them, run the step as
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
    filled_inputs: [{ 'name' => 'email', 'selector' => '[name="email"]',
                      'tag' => 'input', 'type' => 'email',
                      'form_index' => 0, 'value' => unique_email }]
  )
  apply.cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'CV.pdf',
                  content_type: 'application/pdf')
end
```

## FakeSession (browser steps)

Steps that open an `ApplyMate::Client::Browser::Session` (the engine's session scopes: `Stage::ReachForm` /
`DiscoverFields` / `FillFields` / `Submit` / `Verify`, the Navigator, `SmokeSurvey`) are specced against `FakeSession` (`spec/support/fake_session.rb`): same public methods and parameters as `Session` (enforced by
`spec/concepts/apply_mate/client/browser/session_contract_spec.rb`), no browserd.

```ruby
let(:session) { FakeSession.new(html: page_html, final_url: url) } # cookies: '', read_values: {}, missing: [], snapshot:, listbox_options: [], pages: nil
before { stub_browser_session(session) } # Session.open yields it, returns the block value, records the kwargs
```

| Knob / reader | Effect |
|---|---|
| `html:` / `final_url:` / `cookies:` | what `html`, `current_url`, `cookies` (and `goto`'s `NavResult`) return |
| `missing: [css, …]` | a target whose **first** strategy's css is listed is not on the page: `click` / `fill` / `select` / `upload` / `probe` / … raise `TargetNotFound`, `present?` / `ready?` return `false` |
| `read_values: { css => value }` | `probe(:read_value, target)['value']` (and `'displayed'`) for that target; otherwise it echoes the last `fill` / `type` / `select` into the same target. The hash has the real probe's keys (`invalid: false`, `error_text: nil`, `pressed: nil`) |
| `snapshot:` / `show(snapshot, url: nil, html: nil)` | the `ApplyMate::Client::Browser::Snapshot` that `snapshot_all` returns (default `FakeSession::EMPTY_SNAPSHOT`); `show` (not a `Session` method) swaps it, and the `current_url` / `html` when given, e.g. inside `on(:goto)` (the landing page) or `on(:click)` (an action took effect, a thank-you replaced the form). Build snapshots with `build_snapshot` (below) |
| `listbox_options:` | `[Operation::WaitForListbox::Option]` that every `wait_for_listbox` returns (default `[]`); `dom_mark` returns an empty mark |
| `pages:` / `open_page(url)` / `switch_to(index)` | `pages:` (default `[final_url]`) are the open tabs `pages` returns as `[{ 'url' => … }]`; `open_page(url)` (not a `Session` method) appends one, e.g. `session.on(:click) { session.open_page(form_url) }` for a link that opens a tab; `switch_to(index)` makes that tab's URL the `current_url` (`IndexError` for an unknown index) |
| `type` / `wait_until` | `type` appends to the target's echoed value; `wait_until` calls its block once and returns its value or `false` |
| `on(:click) { \|target\| … }` | hook run before a call is handled: read the DB mid-step or `raise` (e.g. a button that vanishes after the claim) |
| `calls` / `calls_of(:click)` | every call as `[method, *args, kwargs]` (kwargs hash only when the method has any), e.g. `[:goto, url]`, `[:settle, :click]`, `[:present?, target, { visibility: :required }]`. `ready?` records `keys:/attr:/ratio:` only in keys mode, `screenshot` records `mask_fillable:` only when true |
| `open_options` | one kwargs hash per `Session.open` (assert `humanize:` and `deadline <= ctx.deadline_at`) |

```ruby
expect(session.calls).to include([ :goto, HoneytechDou::PEOPLEFORCE_URL ])
expect(session.open_options.map { |options| options[:humanize] }).to eq([ false, true ]) # survey, submit

claimed_at_click = []
session.on(:click) { |target| claimed_at_click << Apply.find(apply.id).submit_claimed_at if submit?(target) }
```

**Snapshot builder** (`spec/support/snapshot_builder.rb`, included everywhere): `build_snapshot(frames:, elements:,
markers: [])` returns a real `Snapshot` built by the production `Operation::SnapshotAll` from canned probe output
(refs `f<frame>:e<index>`, fingerprints, Targets with frame paths, digest). `snapshot_element(role:, name:, type:,
tag:, frame:, id:, css:, href:, regions:, **probe_keys)` is one probe element with every key `snapshot.js` returns
(sensible defaults; `regions: [form_css]` puts it inside a form root, `submit_like: true`, `selected: true`, ...).
Pass a `tag > tag:nth-of-type` chain as `css:` when the spec needs DOM ancestry (the Navigator derives the form root
from the claimed refs' css paths).

`spec/support/shared_contexts/honeytech_dou.rb` ('honeytech dou') wires one `FakeSession` (`let(:session)`) for both
leases of the DOU external flow: it starts at `about:blank`, `on(:goto)` shows `peopleforce_form_snapshot` (the
PeopleForce form: 7 controls incl. a contenteditable cover letter and a file input, "Застосувати" submit) with
`peopleforce_form_html`, and a click on `HoneytechDou::PEOPLEFORCE_SUBMIT` shows the thank-you page. Override
`let(:session)` in a context to script `missing:` / `read_values:`.

**The Gemini router** (same context): `stub_gemini_router` answers every Gemini call by reading its prompt
(`gemini_route(text)`) and records `[kind, text]` in `gemini_prompts` (`gemini_prompt_kinds` → `%i[navigate answers cv
verify]`): `GOAL` → Navigate (`gemini_navigate(prompt)`: a frame listing ≥ 3 fillable refs → `form_reached` with exactly
those refs, else click the "Apply" tab, or wait while it is already selected), `Form fields to answer` → AnswerFields
by label (`answers_by_label`, override per spec), ```` ```html ```` → the CV, `submission` → VerifySubmit citing
`verify_quote`. Refs are always parsed from the prompt text, never hard-coded (`f1:e2` changes with the page). The
building blocks (`gemini_navigate_click(ref:)`, `gemini_navigate_wait`, `gemini_navigate_form_reached(scope_ref:,
field_refs:, ...)`, `gemini_answers(prompt)`, `gemini_cv`, `gemini_verify_ok`) return answer texts; a stubbed
browser-backed client reuses the router: its stubbed `complete` joins `request.system` and the message contents into
one prompt and returns `ApplyMate::Ai::Response.new(text: gemini_route(prompt), usage: ApplyMate::Ai::Usage::UNKNOWN)`
(`dou_spec.rb`, GeminiScraping context).

The production path of the engine is covered by the `:browser` e2e specs (`dou_ashby_browser_spec.rb`,
`dou_generic_browser_spec.rb`): the real Session against `FixtureSite`, with only the DOU HTTP and Gemini stubbed
(`allow(Session).to receive(:open).and_wrap_original` undoes the shared context's FakeSession and counts leases).

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
  bound to `0.0.0.0` on **two** free ports, started in `before(:suite)` only when a `:browser` example is selected.
  `FixtureSite.url('/form.html')` = `http://#{FIXTURE_SITE_HOST}:<port>/form.html`; `FixtureSite.alt_url(path)` = the
  same host on `alt_port`, a second **origin** (cross-origin iframes, embeds). `FIXTURE_SITE_HOST` defaults to
  `host.docker.internal`, which the browserd container resolves to the docker host; `browserd-test`'s and CI's
  `EGRESS_ALLOW_RANGES=host.docker.internal` lets smokescreen reach exactly that one address (any port). Both ports
  serve the same routes:
  - `GET /<path>.html|.js` from `pages/` (subdirectories allowed, nothing outside it); in `.html` bodies `{{ORIGIN}}`
    and `{{ALT_ORIGIN}}` become `url('')` / `alt_url('')`. `form.html` sets `fixture_session=abc123`.
  - `GET /ashby/<slug>/<jid uuid>/application` → `ashby/application.html` and `GET /ashby/<slug>/<jid uuid>` →
    `ashby/posting.html` (`FixtureSite::ASHBY_PAGES`). The first is the **canonical form URL** of an Ashby adapter whose
    origin is `alt_url('/ashby')` (`FixtureAshby`, `spec/support/fixture_ashby_platform.rb`), which `ReachForm` and the
    e2e browser spec navigate to; the second is the job URL the embed deep-links for `?ashby_jid=`. A new platform's
    canonical-URL routing goes into the same table.
  - `GET /ashby/posting.json` → `spec/fixtures/files/apply_engine/ashby/api_job_posting.json` (hand-written Ashby
    `ApiJobPosting` answer, no real PII: 15 `fieldEntries` — String ×5, Email, Phone, File, Number, LongText,
    ValueSelect with 15 and with 3 options, Boolean, MultiValueSelect ×2; paths match `ashby/application.html`).
  - `POST /ashby/api/non-user-graphql?op=ApiJobPosting` → the same posting JSON, not recorded (the schema read of
    `Apply::Operation::Platform::Ashby::FetchSchema` with `origin: FixtureSite.alt_url('/ashby')`).
  - `POST /ashby/api/non-user-graphql?op=ApiSubmit<...>` (the submit mutation) → appends `{ op:, body: }` to
    `FixtureSite.submissions` (`Concurrent::Array`, cleared by `FixtureSite.reset!` before every `:browser` example)
    after the `on_submit` hooks ran, and answers `ASHBY_SUBMIT_ANSWERS[FixtureSite.ashby_submit_result]` (`:success`
    by default, the real `FormSubmitSuccess` JSON; `:form_render`: the validation re-render, HTTP 200). Any other op
    (`ApiSetFormValue`, ...) → 200, not recorded. `POST /rum/...` → 202 (the Datadog RUM beacons).
  - `POST /generic/submit` (the JSON post of `generic/widget.html`) → recorded as `{ op: 'generic', body: }` the same
    way (hooks, then `submissions`), answers `{"ok":true}`.
  - `POST /submit` → 200 "Thank you for applying".

  | Page | Contents |
  |---|---|
  | `form.html` | `form#apply`: text (`#full_name`, `maxlength=40`), email (`data-qa`), textarea, native select, checkbox, radio pair, styled toggle (`#remote` hidden, `#remote-root` visible), visually hidden (clip 1px) `#cv` file input with a `label.dropzone`, "Submit application"; plus a newsletter form, so `button[type=submit]` matches twice |
  | `trigger.html` + `slow-reveal.js` | "Apply now" button that injects `form#late-form` 1.5 s after the click |
  | `generic/dialog_form.html` | SSR page with its form already rendered and a 200 ms beacon (Goto's settle must not wait out network idle), an Angular uib-modal whose `type=button "Відгукнутися"` sits in `.modal-footer` outside its `form[name=sendForm]`, and containers with / without stable anchors (probe/anchor.js) |
  | `generic/send_launcher.html` | a landing page whose form sits in a hidden Bootstrap modal behind a type=button `data-toggle=modal` launcher named with a send verb ("Надіслати резюме"): ExecuteAction must click it (`build_field_inventory_browser_spec`) |
  | `generic/forms.html` | three id-less `<form>`s (newsletter email, a type=button "Apply", the application form with a "Resend code" button and a type=submit "Submit application"): `scope` `form@1..3`, "Resend code" is not `submit_like` |
  | `iframe.html` | `form.html` in `iframe#embed` (`name="embedded-form"`) |
  | `challenge.html` | "Just a moment..." title + `cf-chl-` marker, replaced by real content after 2 s |
  | `multi.html` | two identical `button.apply` |
  | `responsive.html` | two `input[name=email]`: `#email_mobile` hidden (`display: none`), `#email_desktop` visible (hidden-duplicate ambiguity) |
  | `widgets.html` | react-select-like `#country-input[role=combobox]` whose menu (`[role=listbox]` + 4 `[role=option]`) is appended to `<body>` on click / ArrowDown and leaves a `.select__single-value` chip; readonly el-select `#city-input` with a pre-rendered hidden `.el-select-dropdown` (`li.el-select-dropdown__item`, no role); yes/no `aria-pressed` buttons in `[role=group]`; `#far-input` below a 1600 px spacer; `#cookie-overlay` that covers the page after 3 s and intercepts clicks (Obstructed); a typeahead `#school-input` (suggestions after 2 characters), a contenteditable `#cover`, native and masked (dd.mm.yyyy) dates, a range `#experience` with an output span, a chooser-only dropzone `#resume-zone` (the file input is created on click) |
  | `wizard.html` | a 2-page SPA wizard in `form#apply`: "Step 1 of 2", a type=button Next that validates page 1, page 1's answers travel as hidden inputs, page 2 posts to `{{ORIGIN}}/submit`; a decoy "Continue reading" outside the form |
  | `new_tab.html` | "Apply for this job" `target=_blank` link to `form.html` (the form opens in a new tab) |
  | `generic/careers.html` | an unknown site (no adapter, no `data-*` markers): vacancy title h1 "AI Animator / Motion Designer", a cookie banner with "Accept all" after 1 s, cross-origin `iframe#apply-widget` → `{{ALT_ORIGIN}}/generic/widget.html` |
  | `generic/widget.html` | `nav[role=tablist]` tabs "Overview" (selected) / "Apply"; Apply mounts a 2-page wizard in `div#application-form`: Full name, Email, Phone, an Element-UI-like readonly select "How did you hear about us?" (LinkedIn / DOU / Friend), "Step 1 of 2", Next; page 2: contenteditable "Cover letter", file "Resume", consent "I agree to the privacy policy", "Step 2 of 2", "Submit application" → JSON `POST {{ALT_ORIGIN}}/generic/submit`, then "Thank you for applying! We received your application." replaces the form |
  | `ashby/company.html` | Preply-like wrapper: no form/iframe in the HTML; `<script src="{{ALT_ORIGIN}}/ashby/embed.js?version=2">` injects `iframe#ashby_embed_iframe` (cross-origin) after 300 ms → `{{ALT_ORIGIN}}/ashby/posting.html?embed=js`, or, when the company page URL carries `?ashby_jid=<uuid>`, → `{{ALT_ORIGIN}}/ashby/preply/<jid>?embed=js` (the job URL detection keys on); a Usercentrics-like banner in an **open shadow root** (`#usercentrics-root`) with "Accept all" / "Accept necessary only" after 1 s |
  | `ashby/embedded_application.html` | company page whose static cross-origin `iframe#ashby_embed_iframe` already shows `{{ALT_ORIGIN}}/ashby/application.html?embed=js`: `ReachForm` without a canonical navigation must find the form root inside the iframe (`reach_form_spec.rb`) |
| `ashby/posting.html` | Ashby description: `nav[role=tablist]` with `a#job-application-form[role=tab]` and `a > button` "Apply for this Job", both → `application.html?embed=js` |
  | `ashby/application.html` | Ashby application page (live_probe Part A), rendered 400 ms after load into `div#form[role=tabpanel]` (no `<form>`): autofill pane with its own hidden file input, `.ashby-application-form-field-entry[data-field-path]` entries, `_required_f7cvd_91` title class, clipped `#_systemfield_resume` + "Upload File", combobox opening **only on ArrowDown** (`div[role=listbox]#:r0:`, 15 options, chip on click), opacity-0 radios and checkboxes whose id/name carry a per-load instance UUID, Yes/No `aria-pressed` buttons, submit `button.ashby-application-form-submit-button` (no type) that POSTs JSON to `/ashby/api/non-user-graphql?op=SubmitApplicationForm` and replaces `#form` with "Thank you for applying" |

- **`FixtureSite.on_submit { |submission| ... }`** runs the block inside the recording POST handler (before the answer
  is sent), e.g. to read `Apply.find(id).submit_claimed_at` at the moment of the POST; hooks are cleared by `reset!`.
- **`FixtureAshby`** (`spec/support/fixture_ashby_platform.rb`) is `Apply::Platform::Ashby` with `origin` =
  `FixtureSite.alt_url('/ashby')` (raises outside a `:browser` example); `canonical_form_url`, the GraphQL URL and the
  signals (host, job URL / frame src, embed script, `?ashby_jid=`, DOM marker) all derive from it, and the signals are
  declared on first use because FixtureSite picks its ports after load. The key stays `ashby` (field ids
  `ashby:<path>`). `stub_fixture_ashby_registry` points `Apply::Platform::Registry.platforms` / `dom_markers` /
  `known_hosts` / `fingerprint` at it; `fixture_ashby_answers_json` is a Gemini AnswerFields reply (confidence 0.95)
  for the fixture posting. Used by `spec/concepts/apply/handler/dou_ashby_browser_spec.rb` (stub
  `ImpersonateHttp.new` with a real instance whose `get` / `post` answer the DOU page, the redirects and the posting;
  wrap `Session.open` with `and_wrap_original` to count leases).
- **Smoke survey** (`Apply::Operation::SmokeSurvey`, `apply:smoke` rake task, `apply_engine.md`): its spec runs the
  real stages on a `FakeSession` (`stub_browser_session`) with a canned Ashby snapshot
  (`application_frames.json` through `SnapshotAll`); the live check is a manual read-only run against the dev
  `browserd` (`:9300`), never part of the suite.
- **PublicAddressGuard seam:** the fixture host is a private address, so `browser_tag.rb` wraps
  `ApplyMate::Net::Operation::ResolvePublicAddress.call` (`and_wrap_original`, in a `before(:each, browser: true)`)
  to return a `Resolution` (`ip: '127.0.0.1'`: the server runs in the spec process, so a pinned `GuardedFetch` of a
  fixture URL works) for URLs on `FixtureSite.host`; every other URL runs the real operation (so
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
      email = unique_email
      session.fill(ApplyMate::Client::Browser::Target.css('#email'), email)

      expect(session.probe(:read_value, ApplyMate::Client::Browser::Target.css('#email'))['value']).to eq(email)
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
# spec/support/shared_contexts/coidea_dou.rb
module CoideaDou
  VACANCY_URL = 'https://jobs.dou.ua/companies/coidea-agency/vacancies/356740/'
end

RSpec.shared_context 'coidea dou' do
  let(:user_email) { unique_email('dev') }      # never a literal: unique_email / unique_phone per use
  let(:vacancy) { create(:vacancy, url: CoideaDou::VACANCY_URL, ...) }

  # Canonical filled inputs of the internal form — reuse in FillForm / SendApply::Http specs
  let(:filled_inputs) { [{ 'name' => 'descr', 'value' => '...', ... }] }

  # Pre-AI state: same fields with blank values (input to FillForm)
  let(:raw_inputs) { filled_inputs.map { |i| i.merge('value' => '') } }
end
```

Each spec `include_context '...'` and adds only what it owns — its HTTP stubs and AI responses.

**Internal-path contexts** (`coidea dou`, `art of spin djinni`) define `filled_inputs` and `raw_inputs` (`raw_inputs`
is always derived from `filled_inputs`); the `FillForm` / `SendApply::Http` specs read them. Include only the fields
relevant to filling and submission.

**External (engine) contexts** (`honeytech dou`) have no `filled_inputs`: the engine stores `fields` / `answers`. They
script the page with a `FakeSession` + `build_snapshot` and answer the AI with the prompt router
(`stub_gemini_router`, see "FakeSession (browser steps)"), because the engine's call order depends on the page (how
many Navigate turns, whether a wizard page brings follow-up answers):

```ruby
before do
  stub_honeytech_redirect_walk
  stub_gemini_router
end
# ...
expect(gemini_prompt_kinds).to eq(%i[navigate answers cv verify])
```

**Internal full-pipeline handler spec** stubs its Gemini calls in order:

```ruby
stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
  .to_return(gemini_json_response(fill_form_json), gemini_json_response(cv_html))
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

## Unique test contacts

Every test email or phone must differ on every use. Use `unique_email(prefix)` / `unique_phone` (`spec/support/unique_contact.rb`, included in all specs) in a `let`, and derive stubs and assertions from that same `let` rather than repeating a literal.
A spec that needs a specific format (e.g. a national `0XXXXXXXXX` number) renders the random digits of `unique_phone`
in that format instead of writing the number out (see `spec/concepts/apply/operation/engine/redact_spec.rb`).

## Profile facts in specs

The `:user_profile` factory sets `facts_cv_digest` to the digest of its CV, so the profile counts as already extracted
and `Stage::AnswerFields` makes no `UserProfile::Operation::ExtractFacts` AI call (ordered AI stubs stay the answer /
CV ones). Pass `facts_cv_digest: nil` to exercise the extraction (`answer_fields_spec.rb`, `extract_facts_spec.rb`);
shared contexts that build a `UserProfile` directly and run the engine (`honeytech_dou.rb`) set it the same way.
