# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin ProxyMate page', type: :request do
  include_context 'with ProxyMate'

  let(:admin)     { create(:user, :admin) }
  let(:sites_url) { "#{ProxyMateSupport::URL}/api/v1/sites" }
  let(:headers)   { { 'Authorization' => "Bearer #{create(:api_token, user: admin).token}" } }
  let(:page)      { Nokogiri::HTML(response.body) }

  let(:turbo_headers) do
    headers.merge('Accept' => 'text/vnd.turbo-stream.html', 'Referer' => admin_proxy_mate_setting_url)
  end

  def stub_sites(status: 200, body: { sites: [] })
    stub_request(:get, sites_url).to_return(status:, body: body.to_json)
  end

  it 'shows the ENV URL prefilled, never the key, and per-site working counts' do
    stub_sites(body: { sites: [ { slug: 'djinni', name: 'Djinni', working: 880, working_with_clearance: 0 } ] })

    get admin_proxy_mate_setting_path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(page.at_css('input[name="proxy_mate_setting[url]"]')['value']).to eq(ProxyMateSupport::URL)
    expect(page.at_css('input[name="proxy_mate_setting[api_key]"]')['type']).to eq('password')
    expect(page.at_css('input[name="proxy_mate_setting[api_key]"]')['value']).to be_nil
    expect(page.at_css('[data-test-id="proxy-mate-site-djinni"]').text).to include('Djinni', '880')
  end

  it 'shows only the first 9 characters of a saved key' do
    ProxyMateSetting.create!(url: ProxyMateSupport::URL, api_key: 'pm_AbCdEfGhIjKlMnOp')
    stub_sites

    get admin_proxy_mate_setting_path, headers: headers

    expect(response.body).to include('pm_AbCdEf…')
    expect(response.body).not_to include('GhIjKlMnOp')
  end

  it 'shows the error instead of crashing when ProxyMate is down' do
    stub_request(:get, sites_url).to_timeout

    get admin_proxy_mate_setting_path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(page.at_css('[data-test-id="proxy-mate-status"]').text).to include('ProxyMate недоступний')
  end

  it 'shows an unauthorized status for a rejected key' do
    stub_sites(status: 401, body: { error: 'unauthorized', message: 'bad key' })

    get admin_proxy_mate_setting_path, headers: headers

    expect(page.at_css('[data-test-id="proxy-mate-status"]').text).to include('unauthorized')
  end

  it 'saves the setting through the form' do
    patch admin_proxy_mate_setting_path,
          params: { proxy_mate_setting: { url: 'https://pm.example.com', api_key: 'pm_Secret123456' } },
          headers: turbo_headers

    expect(response).to have_http_status(:ok)
    expect(ProxyMateSetting.sole).to have_attributes(url: 'https://pm.example.com', api_key: 'pm_Secret123456')
  end

  it 're-renders the form with an error for an invalid URL' do
    patch admin_proxy_mate_setting_path,
          params: { proxy_mate_setting: { url: 'nope' } },
          headers: turbo_headers

    expect(response).to have_http_status(:unprocessable_content)
    expect(ProxyMateSetting.pick(:url)).to be_nil
  end

  it 'is not available to regular users' do
    user_headers = { 'Authorization' => "Bearer #{create(:api_token, user: create(:user)).token}" }

    expect { get admin_proxy_mate_setting_path, headers: user_headers }.to raise_error(Pundit::NotAuthorizedError)
  end
end
