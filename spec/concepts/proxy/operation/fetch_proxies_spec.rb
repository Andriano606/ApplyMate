# frozen_string_literal: true

require "rails_helper"

RSpec.describe Proxy::Operation::FetchProxies, type: :operation do
  subject(:perform) { described_class.call }

  let(:urls) { Proxy::Operation::FetchCandidates::LIST_URLS }

  before do
    urls.each { |url| stub_request(:get, url).to_return(status: 200, body: "") }
    stub_request(:get, urls.first).to_return(status: 200, body: "1.1.1.1:1080\n2.2.2.2:1080\n")
    stub_request(:get, urls.last).to_return(status: 200, body: "1.1.1.1:8080\n")
  end

  it "persists every fetched candidate (no validation step)" do
    expect { perform }.to change(Proxy, :count).by(3)
    expect(Proxy.find_by(host: "1.1.1.1", port: 1080)).to have_attributes(protocol: "socks5")
  end

  it "returns the number of newly inserted proxies" do
    create(:proxy, host: "2.2.2.2", port: 1080, protocol: "socks5")

    expect(perform.model).to eq(2)
  end

  it "prunes stale proxies after fetching" do
    stale = create(:proxy, created_at: (Proxy::Operation::PruneProxies::PRUNE_AFTER + 1.day).ago)

    perform

    expect(Proxy.exists?(stale.id)).to be(false)
  end

  it "persists the fetched proxies even when pruning fails" do
    allow(Proxy::Operation::PruneProxies).to receive(:call).and_raise(ActiveRecord::Deadlocked)

    expect { perform }.to raise_error(ActiveRecord::Deadlocked)
    expect(Proxy.count).to eq(3)
  end
end
