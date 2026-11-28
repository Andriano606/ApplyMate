# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ProxyMateSetting::Operation::Show, type: :operation do
  include_context 'with ProxyMate'

  let(:current_user) { create(:user, :admin) }
  let(:sites_url)    { "#{ProxyMateSupport::URL}/api/v1/sites" }

  def run(user: current_user)
    described_class.call(params: {}, current_user: user)
  end

  it 'reports per-site working counts' do
    stub_request(:get, sites_url).to_return(
      status: 200,
      body: { sites: [ { slug: 'dou', name: 'DOU', working: 41, working_with_clearance: 7 } ] }.to_json
    )

    status = run.model.status

    expect(status.error).to be_nil
    expect(status.sites.map(&:slug)).to eq([ 'dou' ])
    expect(run[:pundit]).to be true
  end

  it 'reports an unauthorized key' do
    stub_request(:get, sites_url).to_return(status: 401, body: { error: 'unauthorized', message: 'bad' }.to_json)

    expect(run.model.status.error).to eq(I18n.t('admin.proxy_mate_setting.status.unauthorized'))
  end

  it 'reports an unreachable ProxyMate instead of raising' do
    stub_request(:get, sites_url).to_timeout

    expect(run.model.status.error).to start_with('ProxyMate недоступний')
  end

  it 'reports a missing configuration without any request' do
    ENV['PROXY_MATE_URL'] = ''

    expect(run.model.status.error).to eq(I18n.t('admin.proxy_mate_setting.status.not_configured'))
    expect(a_request(:any, /proxymate/)).not_to have_been_made
  end

  it 'is denied to a non-admin' do
    expect { run(user: create(:user)) }.to raise_error(Pundit::NotAuthorizedError)
  end
end
