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
RSpec.describe HiddenVacancy::Operation::Create, type: :operation do
  let(:current_user) { create(:user) }
  let(:vacancy)      { create(:vacancy, source: create(:source)) }
  let(:params)       { { vacancy_id: vacancy.hashid } }

  it "hides the vacancy for the user" do
    expect(result).to be_success
    expect(model).to be_persisted
    expect(current_user.hidden_vacancies.pluck(:vacancy_id)).to eq([ vacancy.id ])
  end

  context "when nobody is signed in" do
    let(:current_user) { nil }

    it "is not authorized" do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
```

Real requests deliver `ActionController::Parameters`, not a Hash — wrap `params` in `ActionController::Parameters.new(...)` when the operation relies on parameter methods (see `spec/concepts/vacancy/operation/index_spec.rb`).

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
RSpec.describe Vacancy::Job::SyncVacancies, type: :job do
  it "enqueues without error" do
    expect { described_class.perform_later }
      .to have_enqueued_job(described_class)
  end

  it "runs the operation inline" do
    allow(Vacancy::Operation::SyncVacancies).to receive(:call)
    perform_enqueued_jobs { described_class.perform_now }
    expect(Vacancy::Operation::SyncVacancies).to have_received(:call)
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

**Check enum values before using them in specs** — use an actual value from the model's enum declaration; passing an invalid symbol raises `ArgumentError: 'x' is not a valid status`.

Use `sequence` for columns that must be unique:

```ruby
factory :vacancy do
  sequence(:external_id) { |n| "ext-#{n}" }
  title { "Ruby Developer" }
end
```

## Scraper and Client Specs

Scrapers take `(source, client)`, so pass an `instance_double` of the client class the scraper declares and stub only `get`/`post` (`spec/concepts/apply_mate/scraper/dou_spec.rb`):

```ruby
let(:source)  { create(:source, name: 'Dou', base_url: 'https://jobs.dou.ua', scraper: described_class.name) }
let(:client)  { instance_double(ApplyMate::Client::ImpersonateHttp) }
let(:scraper) { described_class.new(source, client) }

before { allow(client).to receive(:get).and_return(Struct.new(:status, :body).new(200, page_html)) }
```

HTTP-level specs for the clients use WebMock (`spec/support/webmock.rb` — only localhost is allowed, everything else must be stubbed).

## Spec File Naming Convention

Spec files must be named after the **class under test**; the path mirrors the class hierarchy:

| Class | Spec file |
|-------|-----------|
| `Vacancy::Operation::SyncVacancies` | `spec/concepts/vacancy/operation/sync_vacancies_spec.rb` |
| `ApplyMate::Scraper::Dou` | `spec/concepts/apply_mate/scraper/dou_spec.rb` |
| `ApplyMate::Client::AsyncHttp` | `spec/concepts/apply_mate/client/async_http_spec.rb` |

When several fixtures exercise the **same class**, wrap each in a `context` block inside one file — do not create one spec file per fixture or per company.

## Shared Contexts

Defined in `spec/support/` and loaded by `spec/rails_helper.rb`:

| Context / helper | File | Provides |
|---|---|---|
| `"with shared operation spec variables"` | `shared_operation_variables.rb` | `operation`, `result`, `model`, `params`, `current_user` (auto-included for `type: :operation`) |
| `"with elasticsearch index"` | `elasticsearch.rb` | Creates/drops the `Vacancy` index around the example group |
| `ViewComponent::TestHelpers` | `view_component.rb` | Included for `type: :component` |
| WebMock | `webmock.rb` | Blocks real HTTP except localhost |

For setup shared between several spec files, add a `RSpec.shared_context` under `spec/support/`. Keep constants in a companion module — constants inside `RSpec.describe` blocks are silently promoted to `Object` and clash across files.

## Fixture HTML Files

Store real scraped pages under `spec/fixtures/files/<source>/...` (currently `djinni/list/` and `dou/list/`, with per-vacancy pages in `dou/list/details/`). Use the actual production page — not a hand-crafted stub — so CSS selectors reflect reality.
