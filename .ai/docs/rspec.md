# RSpec Patterns

## Shared Operation Context

All specs with `type: :operation` automatically include the `"with shared operation spec variables"` context (wired in `spec/rails_helper.rb`). This provides:

| `let` | Default | Description |
|-------|---------|-------------|
| `operation` | `described_class.new(params:, current_user:)` | Operation instance |
| `result` | `operation.tap(&:call).result` | Result after calling |
| `model` | `result.model` | Shorthand for the result model |
| `params` | `{}` | Override per example/context |
| `current_user` | `nil` | Override with a real user |

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
    expect(apply.reload.status).to eq("completed")
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
    # no `client` — the Source model hardcodes the client in build_scraper

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

**Check enum values before using them in specs** — `Apply` has no `:pending` status. Use an actual value from the model's enum declaration (e.g. `:generating_cv`). Passing an invalid symbol raises `ArgumentError: 'x' is not a valid status`.

Use `sequence` for columns that must be unique:

```ruby
factory :vacancy do
  sequence(:external_id) { |n| "ext-#{n}" }
  title { "Ruby Developer" }
end
```

## Testing Apply Pipeline Operations

`Apply::Operation::*` classes inherit `Apply::Operation::Base` and call `skip_authorize` internally, so invoke them without `current_user:`:

```ruby
described_class.call(apply:)
```

`perform!` sets `start_status` at the top, calls `run!`, then sets `success_status` (if non-nil). After calling:
- `apply.reload.status` reflects the last status set by the operation
- `apply.reload.error` is `nil` on success

Some operations receive extra keyword args via `add_step` options (e.g. `prompt_class:`, `schema_class:`). Pass them explicitly when calling directly:

```ruby
described_class.call(
  apply:,
  prompt_class:  Apply::Ai::Prompt::FillForm,
  schema_class:  Apply::Ai::ResponseSchema::FillForm
)
```

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

## Browser Double

Stub `ApplyMate::Client::Browser` for any spec that exercises browser-based operations:

```ruby
let(:browser) { instance_double(ApplyMate::Client::Browser) }

before do
  allow(ApplyMate::Client::Browser).to receive(:new).and_return(browser)

  allow(browser).to receive(:fetch_rendered).with(url).and_return([final_url, html, ''])
  allow(browser).to receive(:navigate_to)
  allow(browser).to receive(:click).and_return(true)   # must return truthy — falsy raises in operation
  allow(browser).to receive(:fill_field)
  allow(browser).to receive(:attach_file)
  allow(browser).to receive(:attempt_recaptcha_refresh)
  allow(browser).to receive(:wait_for_idle)
  allow(browser).to receive(:body).and_return('<p>Thank you</p>')
  allow(browser).to receive(:screenshot).and_return('')
  allow(browser).to receive(:quit)
end
```

Assert call order with `.ordered`:

```ruby
expect(browser).to have_received(:click).with('#trigger').ordered
expect(browser).to have_received(:click).with('button[type="submit"]', text: 'Apply').ordered
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

  # Canned AI responses reused across specs
  let(:gemini_check_form_page)     { gemini_json_response('{"has_form":true,...}') }
  let(:gemini_check_submit_result) { gemini_json_response('{"success":true,...}') }

  # Canonical filled inputs for this company — reuse in FillForm / SendApply specs
  let(:filled_inputs) { [{ 'name' => 'email', 'value' => 'dev@example.com', ... }] }

  # Pre-AI state: same fields with blank values (input to FillForm)
  let(:raw_inputs) { filled_inputs.map { |i| i.merge('value' => '') } }
end
```

Each spec `include_context 'honeytech dou'` and adds only what it owns — its HTTP stubs and AI response sequence.

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

## Stubbing Gemini (WebMock)

```ruby
def gemini_json_response(text)
  {
    status:  200,
    body:    { candidates: [{ content: { parts: [{ text: }] } }] }.to_json,
    headers: { 'Content-Type' => 'application/json' }
  }
end

stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
  .to_return(gemini_json_response('```json\n{"key":"value"}\n```'))
```

Always suppress `Apply::TurboHandler::StatusUpdate.broadcast` and `Grover#to_pdf` in specs that run operations end-to-end:

```ruby
before do
  allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
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
