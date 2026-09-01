require 'rails_helper'

RSpec.describe 'Saved filter pills', type: :request do
  include_context 'with elasticsearch index'

  after do
    Elasticsearch::Model.client.delete_by_query(
      index:   Vacancy.index_name,
      body:    { query: { match_all: {} } },
      refresh: true
    )
  end

  let(:user)    { create(:user) }
  let(:token)   { user.api_tokens.create!.token }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:source)  { create(:source) }

  let!(:ruby)   { preset('Ruby', 'ruby') }
  let!(:python) { preset('Python', 'python') }
  let!(:java)   { preset('Java', 'java') }

  def preset(name, tag)
    create(:saved_filter, user:, name:, include_tags: [ tag ], include_ops: [], exclude_tags: [])
  end

  def index_vacancy(title)
    create(:vacancy, source:, title:, company_name: 'Corp', description: 'role')
      .tap { |vacancy| vacancy.__elasticsearch__.index_document }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def pill(saved_filter)
    document.at_css(%([data-test-id="saved-filter-pills"] [data-model-id="#{saved_filter.id}"]))
  end

  # The pill renders "<count>" plus optional "+appeared" / "−disappeared" badges.
  def deltas(saved_filter)
    pill(saved_filter).css('span').map(&:text).grep(/\A[+−]\d+\z/)
  end

  def open_preset(saved_filter)
    get pill(saved_filter).at_css('a')['href'], headers: headers
  end

  before do
    # Every preset was opened once, when it matched exactly one vacancy...
    %w[Ruby Python Java].each { |language| index_vacancy("#{language} Developer") }
    Vacancy.__elasticsearch__.refresh_index!
    get '/vacancies', headers: headers
    [ ruby, python, java ].each { |saved_filter| open_preset(saved_filter) }

    # ...and a sync has since added one new vacancy to each of them.
    %w[Ruby Python Java].each { |language| index_vacancy("#{language} Engineer") }
    Vacancy.__elasticsearch__.refresh_index!

    get '/vacancies', headers: headers
  end

  it 'shows the appeared delta on every preset that has new vacancies' do
    expect(deltas(ruby)).to   eq([ '+1' ])
    expect(deltas(python)).to eq([ '+1' ])
    expect(deltas(java)).to   eq([ '+1' ])
  end

  it 'clears the deltas of the opened preset only' do
    open_preset(ruby)

    expect(deltas(ruby)).to   be_empty
    expect(deltas(python)).to eq([ '+1' ])
    expect(deltas(java)).to   eq([ '+1' ])
  end

  it 'leaves the view snapshot of the other presets untouched' do
    snapshot = ->(f) { f.reload.slice(:last_seen_count, :last_seen_max_vacancy_id) }
    before_python = snapshot[python]
    before_java   = snapshot[java]

    open_preset(ruby)

    expect(snapshot[python]).to eq(before_python)
    expect(snapshot[java]).to   eq(before_java)
  end

  # Turbo 8 prefetches links on hover, and opening a preset records its view
  # snapshot — so without the opt-out, sweeping the pointer across the row
  # consumed the deltas of every pill it passed over.
  it 'opts the pill links out of Turbo hover prefetching' do
    link = pill(ruby).at_css('a')

    expect(link.ancestors('[data-turbo-prefetch="false"]')).not_to be_empty
  end
end
