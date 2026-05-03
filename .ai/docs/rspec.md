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
    client   { "ApplyMate::Client::Http" }

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

Use `sequence` for columns that must be unique:

```ruby
factory :vacancy do
  sequence(:external_id) { |n| "ext-#{n}" }
  title { "Ruby Developer" }
end
```
