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

    it 'stops accepting a personal token once it has been regenerated' do
      personal = create(:api_token, user:, personal: true)
      old_value = personal.token
      ping = { jsonrpc: '2.0', id: 1, method: 'ping' }

      mcp_post(ping, auth: "Bearer #{old_value}")
      expect(response).to have_http_status(:ok)

      McpConnection::Operation::Update.call(params: {}, current_user: user)

      mcp_post(ping, auth: "Bearer #{old_value}")
      expect(response).to have_http_status(:unauthorized)

      mcp_post(ping, auth: "Bearer #{personal.reload.token}")
      expect(response).to have_http_status(:ok)
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
                                     'list_saved_filters', 'set_vacancy_hidden',
                                     'get_my_feedback', 'list_feedback', 'submit_feedback', 'reply_to_feedback', 'delete_feedback')
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

  describe 'get_my_feedback' do
    it 'returns null before the user left any feedback' do
      create(:feedback) # somebody else's

      expect(tool_data('get_my_feedback')).to eq('feedback' => nil, 'unread_replies' => 0)
    end

    it "returns the user's own feedback only" do
      mine = create(:feedback, user:, rating: 8, body: 'Solid', posted_via: 'web')
      create(:feedback)

      data = tool_data('get_my_feedback')

      expect(data['feedback']).to include('id' => mine.to_param, 'rating' => 8, 'sentiment' => 'positive',
                                          'comment' => 'Solid', 'posted_via' => 'web')
    end
  end

  describe 'get_my_feedback replies' do
    it 'returns the thread with roles, oldest first' do
      mine  = create(:feedback, user:)
      admin = create(:user, :admin, name: 'Support Admin')
      create(:feedback_reply, feedback: mine, user: admin, body: 'Thanks!', created_at: 2.hours.ago)
      create(:feedback_reply, feedback: mine, user:, body: 'You are welcome', created_at: 1.hour.ago)

      replies = tool_data('get_my_feedback').dig('feedback', 'replies')

      expect(replies).to match([
        a_hash_including('author' => 'Support Admin', 'role' => 'admin', 'comment' => 'Thanks!'),
        a_hash_including('author' => user.name, 'role' => 'author', 'comment' => 'You are welcome')
      ])
    end

    it 'returns an empty thread when nobody replied' do
      create(:feedback, user:)

      expect(tool_data('get_my_feedback').dig('feedback', 'replies')).to eq([])
    end
  end

  describe 'get_my_feedback unread replies' do
    let(:admin) { create(:user, :admin, name: 'Support Admin') }
    let!(:mine) { create(:feedback, user:) }

    it 'counts unread replies, flags them new and reads them' do
      seen   = create(:feedback_reply, feedback: mine, user: admin, body: 'Old', created_at: 3.hours.ago)
      FeedbackThreadRead.mark_seen!(user, { mine.id => seen.created_at })
      create(:feedback_reply, feedback: mine, user: admin, body: 'Fresh', created_at: 1.hour.ago)

      first  = tool_data('get_my_feedback')
      second = tool_data('get_my_feedback')

      expect(first['unread_replies']).to eq(1)
      expect(first['feedback']['replies'].map { |r| [ r['comment'], r['new'] ] }).to eq([ [ 'Old', false ], [ 'Fresh', true ] ])
      expect(second['unread_replies']).to eq(0)
      expect(second['feedback']['replies'].map { |r| r['new'] }).to eq([ false, false ])
    end

    it 'gives a role of nil to a reply of a demoted admin' do
      former = create(:user, :admin)
      create(:feedback_reply, feedback: mine, user: former)
      former.update!(admin: false)

      expect(tool_data('get_my_feedback').dig('feedback', 'replies', 0, 'role')).to be_nil
    end
  end

  describe 'list_feedback' do
    let!(:positive) { create(:feedback, rating: 9, body: 'Loved it', updated_at: 2.days.ago) }
    let!(:negative) { create(:feedback, rating: 2, body: 'Hated it', updated_at: 1.day.ago) }

    it 'lists others\' reviews with the author, stats and pagination' do
      data = tool_data('list_feedback')

      expect(data['feedbacks'].map { |f| f['comment'] }).to eq([ 'Hated it', 'Loved it' ])
      expect(data['feedbacks'].first).to include('author' => negative.user.name, 'id' => negative.to_param,
                                                 'sentiment' => 'negative')
      expect(data['own_feedback']).to be_nil
      expect(data['stats']).to include('total' => 2, 'average' => 5.5)
      expect(data['pagination']).to include('page' => 1, 'total_entries' => 2, 'next_page' => nil)
    end

    it 'filters by sentiment' do
      data = tool_data('list_feedback', { sentiment: 'positive' })

      expect(data['feedbacks'].map { |f| f['comment'] }).to eq([ 'Loved it' ])
      expect(data['stats']['total']).to eq(2)
    end

    it 'rejects an unknown sentiment at the schema level' do
      expect(call_tool('list_feedback', { sentiment: 'angry' })['isError']).to be(true)
    end

    it 'returns the own review separately, never in the list' do
      create(:feedback, user:, body: 'Mine')

      data = tool_data('list_feedback')

      expect(data['own_feedback']).to include('comment' => 'Mine')
      expect(data['own_feedback']).not_to have_key('author')
      expect(data['feedbacks'].map { |f| f['comment'] }).not_to include('Mine')
    end

    it 'flags unread replies under the own review as new and marks them seen' do
      mine = create(:feedback, user:)
      create(:feedback_reply, feedback: mine, user: create(:user, :admin), body: 'Hello')

      first  = tool_data('list_feedback')
      second = tool_data('list_feedback')

      expect(first['own_feedback']['replies'].first).to include('comment' => 'Hello', 'new' => true)
      expect(second['own_feedback']['replies'].first).to include('new' => false)
      expect(user.unread_feedback_reply_count).to eq(0)
    end
  end

  describe 'reply_to_feedback' do
    let(:admin_user)  { create(:user, :admin) }
    let(:admin_token) { create(:api_token, user: admin_user).token }

    def call_as(auth_token, arguments)
      mcp_post({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'reply_to_feedback', arguments: } },
               auth: "Bearer #{auth_token}")
      JSON.parse(response.body).fetch('result')
    end

    it "posts under the user's own feedback by default and returns the thread" do
      mine = create(:feedback, user:)
      create(:feedback_reply, feedback: mine, body: 'Admin question')

      data = tool_data('reply_to_feedback', { comment: 'My answer' })

      expect(data['feedback']['id']).to eq(mine.to_param)
      expect(data['feedback']['replies'].map { |r| [ r['role'], r['comment'] ] })
        .to eq([ [ 'admin', 'Admin question' ], [ 'author', 'My answer' ] ])
      expect(mine.replies.last).to have_attributes(user:, body: 'My answer')
    end

    it 'lets an admin reply under any feedback by id' do
      other = create(:feedback)

      result = call_as(admin_token, { comment: 'Thanks!', feedback_id: other.to_param })

      expect(result['isError']).to be(false)
      expect(other.replies.reload.map { |r| [ r.user, r.body ] }).to eq([ [ admin_user, 'Thanks!' ] ])
      expect(JSON.parse(result['content'].first['text']).dig('feedback', 'replies', 0, 'role')).to eq('admin')
    end

    it 'refuses a non-admin under somebody else\'s feedback' do
      other = create(:feedback)

      result = call_tool('reply_to_feedback', { comment: 'Sneaky', feedback_id: other.to_param })

      expect(result['isError']).to be(true)
      expect(result['content'].first['text']).to eq(I18n.t('mcp.errors.reply_forbidden'))
      expect(other.replies).to be_empty
    end

    it 'reports an unknown id' do
      result = call_tool('reply_to_feedback', { comment: 'Hi', feedback_id: 'nope' })

      expect(result['isError']).to be(true)
      expect(result['content'].first['text']).to eq(I18n.t('mcp.errors.unknown_feedback', id: 'nope'))
      expect(FeedbackReply.count).to eq(0)
    end

    it 'reports a missing own feedback when no id is given' do
      create(:feedback) # somebody else's

      result = call_tool('reply_to_feedback', { comment: 'Hello' })

      expect(result['isError']).to be(true)
      expect(result['content'].first['text']).to eq(I18n.t('mcp.errors.no_feedback'))
      expect(FeedbackReply.count).to eq(0)
    end

    it 'rejects an empty or oversized comment at the schema level' do
      create(:feedback, user:)

      [ '', 'a' * (FeedbackReply::BODY_MAX_LENGTH + 1) ].each do |comment|
        expect(call_tool('reply_to_feedback', { comment: })['isError']).to be(true)
      end
      expect(FeedbackReply.count).to eq(0)
    end

    it 'reports a full thread as a readable tool error' do
      mine = create(:feedback, user:)
      stub_const('FeedbackReply::MAX_PER_FEEDBACK', 1)
      create(:feedback_reply, feedback: mine)

      result = call_tool('reply_to_feedback', { comment: 'One too many' })

      expect(result['isError']).to be(true)
      expect(result['content'].first['text']).to eq(I18n.t('feedback_reply.errors.thread_full', count: 1))
    end
  end

  describe 'list_feedback unread_only' do
    let(:admin) { create(:user, :admin) }

    it 'lists only threads with unread replies, flags them new and then reads them' do
      replied = create(:feedback)
      create(:feedback_reply, feedback: replied, user: admin, body: 'Question', created_at: 2.days.ago)
      FeedbackThreadRead.mark_seen!(user, { replied.id => 1.day.ago })
      create(:feedback_reply, feedback: replied, user: admin, body: 'Follow-up', created_at: 1.minute.ago)
      create(:feedback, body: 'Quiet thread')

      first  = tool_data('list_feedback', { unread_only: true })
      second = tool_data('list_feedback', { unread_only: true })

      expect(first['feedbacks'].map { |f| f['id'] }).to eq([ replied.to_param ])
      expect(first['feedbacks'].first['replies'].map { |r| r['new'] }).to eq([ false, true ])
      expect(second['feedbacks']).to be_empty
    end
  end

  describe 'delete_feedback' do
    let(:admin_token) { create(:api_token, user: create(:user, :admin)).token }

    def call_as(auth_token, arguments)
      mcp_post({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'delete_feedback', arguments: } },
               auth: "Bearer #{auth_token}")
      JSON.parse(response.body).fetch('result')
    end

    it 'deletes the own feedback with its thread by default' do
      mine = create(:feedback, user:)
      create(:feedback_reply, feedback: mine)

      data = tool_data('delete_feedback')

      expect(data).to eq('deleted' => true, 'id' => mine.to_param)
      expect(Feedback.where(user:)).to be_empty
      expect(FeedbackReply.count).to eq(0)
    end

    it 'lets the user publish again afterwards' do
      create(:feedback, user:)
      tool_data('delete_feedback')

      expect(tool_data('submit_feedback', { rating: 8, comment: 'Again' })['created']).to be(true)
    end

    it 'lets an admin delete any feedback by id' do
      other = create(:feedback)

      result = call_as(admin_token, { feedback_id: other.to_param })

      expect(result['isError']).to be(false)
      expect(Feedback.exists?(other.id)).to be(false)
    end

    it 'refuses a non-admin with another user\'s id with a readable tool error' do
      other = create(:feedback)

      result = call_tool('delete_feedback', { feedback_id: other.to_param })

      expect(result['isError']).to be(true)
      expect(result['content'].first['text']).to eq(I18n.t('mcp.errors.delete_forbidden'))
      expect(Feedback.exists?(other.id)).to be(true)
    end

    it 'reports an unknown id' do
      result = call_tool('delete_feedback', { feedback_id: 'nope' })

      expect(result['isError']).to be(true)
      expect(result['content'].first['text']).to eq(I18n.t('mcp.errors.unknown_feedback', id: 'nope'))
    end

    it 'reports a missing own feedback' do
      create(:feedback)

      result = call_tool('delete_feedback')

      expect(result['isError']).to be(true)
      expect(result['content'].first['text']).to eq(I18n.t('mcp.errors.no_feedback'))
      expect(Feedback.count).to eq(1)
    end
  end

  describe 'submit_feedback' do
    it 'creates the feedback, signed as an MCP post' do
      data = nil
      expect { data = tool_data('submit_feedback', { rating: 9, comment: 'Great bank' }) }
        .to change { Feedback.where(user:).count }.from(0).to(1)

      expect(data['created']).to be(true)
      expect(data['feedback']).to include('rating' => 9, 'comment' => 'Great bank',
                                          'sentiment' => 'positive', 'posted_via' => 'mcp')
      expect(user.reload.feedback).to have_attributes(rating: 9, body: 'Great bank', posted_via: 'mcp')
    end

    it 'replaces the single feedback on the next call' do
      create(:feedback, user:, rating: 3, body: 'Old text', posted_via: 'web')

      data = tool_data('submit_feedback', { rating: 6, comment: 'New text' })

      expect(data['created']).to be(false)
      expect(data['feedback']).to include('rating' => 6, 'sentiment' => 'neutral', 'posted_via' => 'mcp')
      expect(Feedback.where(user:).count).to eq(1)
      expect(user.reload.feedback).to have_attributes(rating: 6, body: 'New text', posted_via: 'mcp')
    end

    it 'creates first and replaces second across two calls' do
      first  = tool_data('submit_feedback', { rating: 5, comment: 'One' })
      second = tool_data('submit_feedback', { rating: 7, comment: 'Two' })

      expect([ first['created'], second['created'] ]).to eq([ true, false ])
      expect(first['feedback']['id']).to eq(second['feedback']['id'])
    end

    it 'does not touch other users feedback' do
      other = create(:feedback, body: 'Not mine')

      tool_data('submit_feedback', { rating: 8, comment: 'Mine' })

      expect(other.reload.body).to eq('Not mine')
    end

    it 'reports a model validation failure as a readable tool error' do
      too_long = 'a' * (Feedback::BODY_MAX_LENGTH + 1)
      result = Mcp::Operation::SubmitFeedback.call(params: { rating: 5, comment: too_long }, current_user: user)

      expect(result).to be_failure
      expect(result.error_message).to be_present
      expect(Feedback.where(user:)).to be_empty
    end

    it 'rejects out-of-range input at the schema level' do
      [ { rating: 11, comment: 'x' }, { rating: 0, comment: 'x' }, { rating: 5, comment: '' },
        { rating: 5, comment: 'a' * (Feedback::BODY_MAX_LENGTH + 1) } ].each do |arguments|
        result = call_tool('submit_feedback', arguments)

        expect(result['isError']).to be(true)
      end
      expect(Feedback.where(user:)).to be_empty
    end
  end
end
