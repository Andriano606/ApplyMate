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

  def preset(name, tag)
    create(:saved_filter, user:, name:, include_tags: [ tag ], include_ops: [], exclude_tags: [])
  end

  def index_vacancy(title)
    create(:vacancy, source:, title:, company_name: 'Corp', description: 'role')
      .tap { |vacancy| vacancy.__elasticsearch__.index_document }
  end

  def pill_badges(saved_filter)
    Nokogiri::HTML(response.body)
            .at_css(%([data-test-id="saved-filter-pills"] [data-model-id="#{saved_filter.id}"]))
            .css('span').map { |badge| badge.text.strip }
  end

  before do
    [ 'Ruby Developer', 'Ruby Engineer', 'Python Developer' ].each { |title| index_vacancy(title) }
    Vacancy.__elasticsearch__.refresh_index!
  end

  it 'shows only how many vacancies each preset matches now' do
    get '/vacancies', headers: headers

    expect(pill_badges(ruby)).to eq([ '2' ])
    expect(pill_badges(python)).to eq([ '1' ])
  end

  it 'opening a preset leaves the preset untouched' do
    get '/vacancies', headers:, params: { saved_filter_id: ruby.hashid, include_tags: [ 'ruby' ] }

    expect(response).to have_http_status(:ok)
    expect(ruby.reload.updated_at).to eq(ruby.created_at)
  end
end
