# frozen_string_literal: true

require "rails_helper"

RSpec.describe Proxy::Operation::FetchProxies, type: :operation do
  subject(:perform) { described_class.call }

  let(:candidates) do
    [
      { host: "1.1.1.1", port: 8080, protocol: "http" },
      { host: "2.2.2.2", port: 1080, protocol: "socks5" }
    ]
  end

  before do
    fetch_result = instance_double(ApplyMate::Operation::Result, model: candidates)
    allow(Proxy::Operation::FetchCandidates).to receive(:call).and_return(fetch_result)
  end

  it "persists every fetched candidate as-is (no validation step)" do
    expect { perform }.to change(Proxy, :count).by(2)
  end

  it "returns the number of persisted proxies" do
    expect(perform.model).to eq(2)
  end

  it "passes the fetched candidates straight to PersistProxies" do
    expect(Proxy::Operation::PersistProxies)
      .to receive(:call).with(proxies: candidates).and_call_original

    perform
  end
end
