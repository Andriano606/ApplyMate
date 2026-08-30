# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Proxy::Operation::Validate, type: :operation do
  let!(:source) { create(:source, name: 'Dou', base_url: 'https://jobs.dou.ua') }
  let!(:alive)  { create(:proxy, host: 'alive.example.com') }
  let!(:dead)   { create(:proxy, host: 'dead.example.com') }

  before do
    # Reachable only for the "alive" proxy; everything else returns a dead status.
    allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get) do |instance, url|
      proxy_uri = instance.instance_variable_get(:@proxy_uri)
      status    = proxy_uri&.host == 'alive.example.com' ? 200 : 503
      ApplyMate::Client::AsyncHttp::Response.new('robots', {}, status, url)
    end
  end

  it 'records per-source stats: working for reachable proxies, dead for the rest' do
    result = described_class.call(limit: 10, sources: [ source ]).model

    expect(result[:validated]).to eq(2)
    expect(result[:alive][source.id]).to eq(1)

    expect(ProxySourceStat.find_by(proxy: alive, source: source))
      .to have_attributes(success_count: 1, fail_count: 0, reliability: 1.0)
    dead_stat = ProxySourceStat.find_by(proxy: dead, source: source)
    expect(dead_stat).to have_attributes(success_count: 0, fail_count: 1, reliability: 0.0)
    expect(dead_stat.failed_at).to be_present
  end

  it 'accepts a 403 Cloudflare challenge as alive, but not a plain 403 block' do
    challenged = create(:proxy, host: 'cf.example.com')
    hardblock  = create(:proxy, host: 'blocked.example.com')
    allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get) do |instance, url|
      host = instance.instance_variable_get(:@proxy_uri)&.host
      body, status = case host
      when 'cf.example.com'      then [ '<title>Just a moment...</title>', 403 ]
      when 'blocked.example.com' then [ 'error 1020: access denied', 403 ]
      else [ 'robots', 503 ]
      end
      ApplyMate::Client::AsyncHttp::Response.new(body, {}, status, url)
    end

    described_class.call(limit: 10, sources: [ source ])

    # CF challenge → alive (ImpersonateHttp clears it when scraping); 1020 block → dead.
    expect(ProxySourceStat.find_by(proxy: challenged, source: source)).to have_attributes(success_count: 1, fail_count: 0)
    expect(ProxySourceStat.find_by(proxy: hardblock, source: source)).to have_attributes(success_count: 0, fail_count: 1)
  end

  it 'probes only proxies without stats yet under the default scope' do
    tested = create(:proxy, host: 'tested.example.com')
    ProxySourceStat.create!(proxy: tested, source: source, success_count: 5, reliability: 1.0)

    described_class.call(limit: 10, sources: [ source ])

    expect(ProxySourceStat.find_by(proxy: tested, source: source).success_count).to eq(5)
  end
end
