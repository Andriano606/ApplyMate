# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'MCP endpoint', type: :request do
  include_context 'with elasticsearch index'

  after do
    Elasticsearch::Model.client.delete_by_query(
      index: Vacancy.index_name, body: { query: { match_all: {} } }, refresh: true
    )
  end

  let(:user)  { create(:user) }
  let(:token) { create(:api_token, user:).token }

  let(:djinni) { create(:source, name: 'Djinni') }
  let(:dou)    { create(:source, name: 'Dou', scraper: 'ApplyMate::Scraper::Dou') }

  let!(:rails_vacancy) do
    create(:vacancy, source: djinni, title: 'Ruby on Rails Developer', company_name: 'Acme',
                     description: 'Rails, remote', description_html: '<p>Rails, <b>remote</b></p>')
  end
  let!(:python_vacancy) do
    create(:vacancy, source: dou, title: 'Python Engineer', company_name: 'Globex',
                     description: 'Python, віддалено')
  end

  before { Vacancy.__elasticsearch__.refresh_index! }

  def mcp_post(body, auth: "Bearer #{token}")
    headers = { 'Content-Type' => 'application/json', 'Accept' => 'application/json, text/event-stream',
                'MCP-Protocol-Version' => '2025-06-18' }
    headers['Authorization'] = auth if auth
    post '/mcp', params: body.to_json, headers:
  end

  def call_tool(name, arguments = {})
    mcp_post({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name:, arguments: } })
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body).fetch('result')
  end

  def tool_data(name, arguments = {})
    result = call_tool(name, arguments)
    expect(result['isError']).to be(false), result['content'].inspect
    JSON.parse(result['content'].first['text'])
  end

  describe 'authentication' do
    it 'rejects requests without a token with 401 and a Bearer challenge' do
      mcp_post({ jsonrpc: '2.0', id: 1, method: 'tools/list' }, auth: nil)

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['WWW-Authenticate']).to start_with('Bearer')
    end

    it 'rejects an unknown token' do
      mcp_post({ jsonrpc: '2.0', id: 1, method: 'tools/list' }, auth: 'Bearer nope')

      expect(response).to have_http_status(:unauthorized)
    end

    it 'records when the token was last used' do
      api_token = create(:api_token, user:)

      expect { mcp_post({ jsonrpc: '2.0', id: 1, method: 'ping' }, auth: "Bearer #{api_token.token}") }
        .to change { api_token.reload.last_used_at }.from(nil)
    end
  end

  it 'answers initialize with the server info, instructions and only the tools capability' do
    mcp_post({ jsonrpc: '2.0', id: 1, method: 'initialize',
               params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'spec', version: '1' } } })

    result = JSON.parse(response.body).fetch('result')
    expect(result['serverInfo']).to include('name' => 'applymate')
    expect(result['instructions']).to include('search_vacancies')
    expect(result['capabilities'].keys).to eq([ 'tools' ])
  end

  it 'lists every tool' do
    mcp_post({ jsonrpc: '2.0', id: 1, method: 'tools/list' })

    names = JSON.parse(response.body).dig('result', 'tools').map { |tool| tool['name'] }
    expect(names).to contain_exactly('search_vacancies', 'get_vacancies', 'list_sources',
                                     'list_saved_filters', 'set_vacancy_hidden')
  end

  describe 'search_vacancies' do
    it 'searches with a boolean query and returns summaries with pagination' do
      data = tool_data('search_vacancies', { query: 'rails або python' })

      expect(data['vacancies'].map { |v| v['id'] }).to eq([ python_vacancy.to_param, rails_vacancy.to_param ])
      expect(data['vacancies'].last).to include('title' => 'Ruby on Rails Developer', 'source' => 'Djinni',
                                                'snippet' => 'Rails, remote', 'hidden' => false)
      expect(data['pagination']).to include('page' => 1, 'total_entries' => 2, 'next_page' => nil)
    end

    it 'filters by source name or id' do
      by_name = tool_data('search_vacancies', { sources: [ 'dou' ] })
      by_id   = tool_data('search_vacancies', { sources: [ djinni.to_param ] })

      expect(by_name['vacancies'].map { |v| v['id'] }).to eq([ python_vacancy.to_param ])
      expect(by_id['vacancies'].map { |v| v['id'] }).to eq([ rails_vacancy.to_param ])
    end

    it 'applies exclude' do
      data = tool_data('search_vacancies', { exclude: [ 'pyth' ] })

      expect(data['vacancies'].map { |v| v['id'] }).to eq([ rails_vacancy.to_param ])
    end

    it "runs one of the user's saved filters, narrowed by query" do
      filter = create(:saved_filter, user:, include_tags: [ 'rails', 'python' ], include_ops: [ 'or' ], exclude_tags: [])

      all_of_filter = tool_data('search_vacancies', { saved_filter_id: filter.to_param })
      narrowed      = tool_data('search_vacancies', { saved_filter_id: filter.to_param, query: 'віддалено' })

      expect(all_of_filter['pagination']['total_entries']).to eq(2)
      expect(narrowed['vacancies'].map { |v| v['id'] }).to eq([ python_vacancy.to_param ])
    end

    it "refuses another user's saved filter" do
      foreign = create(:saved_filter)

      result = call_tool('search_vacancies', { saved_filter_id: foreign.to_param })

      expect(result['isError']).to be(true)
      expect(result['content'].first['text']).to include(foreign.to_param)
    end

    it 'reports unknown sources with the available ones' do
      djinni

      result = call_tool('search_vacancies', { sources: [ 'linkedin' ] })

      expect(result['isError']).to be(true)
      expect(result['content'].first['text']).to include('linkedin', 'Djinni')
    end

    it 'skips hidden vacancies unless include_hidden is set' do
      user.hidden_vacancies.create!(vacancy: rails_vacancy)

      default = tool_data('search_vacancies')
      with_hidden = tool_data('search_vacancies', { include_hidden: true })

      expect(default['vacancies'].map { |v| v['id'] }).to eq([ python_vacancy.to_param ])
      expect(with_hidden['vacancies'].find { |v| v['id'] == rails_vacancy.to_param }['hidden']).to be(true)
    end

    it 'stops next_page at the deepest page Elasticsearch can serve' do
      stub_const('Vacancy::MAX_RESULT_WINDOW', 2) # 2 matches, 1 per page => last page is 2

      first = tool_data('search_vacancies', { per_page: 1 })
      last  = tool_data('search_vacancies', { per_page: 1, page: 2 })
      stub_const('Vacancy::MAX_RESULT_WINDOW', 1)
      capped = tool_data('search_vacancies', { per_page: 1 })

      expect(first['pagination']).to include('total_pages' => 2, 'next_page' => 2)
      expect(last['pagination']).to include('next_page' => nil)
      expect(capped['pagination']).to include('total_entries' => 2, 'total_pages' => 1, 'next_page' => nil)
    end

    it 'rejects arguments outside the schema' do
      result = call_tool('search_vacancies', { per_page: 1000 })

      expect(result['isError']).to be(true)
    end
  end

  describe 'get_vacancies' do
    it 'returns every stored field in the order asked and reports missing ids' do
      data = tool_data('get_vacancies', { ids: [ python_vacancy.to_param, 'gone', rails_vacancy.to_param ] })

      expect(data['vacancies'].map { |v| v['id'] }).to eq([ python_vacancy.to_param, rails_vacancy.to_param ])
      expect(data['vacancies'].last).to include(
        'title' => 'Ruby on Rails Developer', 'company_name' => 'Acme', 'url' => rails_vacancy.url,
        'external_id' => rails_vacancy.external_id, 'description' => 'Rails, remote', 'hidden' => false,
        'source' => { 'id' => djinni.to_param, 'name' => 'Djinni', 'base_url' => djinni.base_url }
      )
      expect(data['vacancies'].last).not_to have_key('description_html')
      expect(data['missing_ids']).to eq([ 'gone' ])
    end

    it 'includes the markup on request' do
      data = tool_data('get_vacancies', { ids: [ rails_vacancy.to_param ], include_html: true })

      expect(data['vacancies'].first['description_html']).to eq('<p>Rails, <b>remote</b></p>')
    end
  end

  it 'list_sources returns every source with its live vacancy count' do
    data = tool_data('list_sources')

    expect(data['sources']).to contain_exactly(
      a_hash_including('id' => djinni.to_param, 'name' => 'Djinni', 'vacancy_count' => 1),
      a_hash_including('id' => dou.to_param, 'name' => 'Dou', 'vacancy_count' => 1,
                       'listing_url' => dou.listing_url)
    )
  end

  it "list_saved_filters returns only the user's own filters" do
    mine = create(:saved_filter, user:, name: 'Embedded')
    create(:saved_filter, name: 'Not mine')

    data = tool_data('list_saved_filters')

    expect(data['saved_filters']).to eq([
      { 'id' => mine.to_param, 'name' => 'Embedded', 'include_tags' => mine.include_tags,
        'include_ops' => mine.include_ops, 'exclude_tags' => mine.exclude_tags }
    ])
  end

  describe 'set_vacancy_hidden' do
    it 'hides and restores a vacancy idempotently' do
      2.times { tool_data('set_vacancy_hidden', { id: rails_vacancy.to_param }) }
      expect(user.hidden_vacancies.pluck(:vacancy_id)).to eq([ rails_vacancy.id ])

      2.times { tool_data('set_vacancy_hidden', { id: rails_vacancy.to_param, hidden: false }) }
      expect(user.hidden_vacancies).to be_empty
    end

    it 'reports an unknown vacancy as a tool error' do
      result = call_tool('set_vacancy_hidden', { id: 'gone' })

      expect(result['isError']).to be(true)
      expect(user.hidden_vacancies).to be_empty
    end
  end
end
