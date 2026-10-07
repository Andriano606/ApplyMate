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

## Spec File Naming Convention

Spec files must be named after the **class under test**, not after the company/fixture. The path mirrors the class hierarchy:

| Class                                 | Spec file                                                   |
| ------------------------------------- | ----------------------------------------------------------- |
| `Apply::Operation::FetchInternalForm` | `spec/concepts/apply/operation/fetch_internal_form_spec.rb` |
| `Apply::Operation::SendApply::Http`   | `spec/concepts/apply/operation/send_apply/http_spec.rb`     |
| `Apply::Handler::Dou`                 | `spec/concepts/apply/handler/dou_spec.rb`                   |

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
