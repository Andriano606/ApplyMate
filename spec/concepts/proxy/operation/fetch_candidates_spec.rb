# frozen_string_literal: true

require "rails_helper"

RSpec.describe Proxy::Operation::FetchCandidates, type: :operation do
  subject(:perform) { described_class.call(on_batch:, urls:, **limits) }

  # The sink is called from inside the Async reactor, so it must not touch a lazy `let`:
  # RSpec memoizes under a mutex the outer fiber already holds while building `perform`.
  let(:batches)  { [] }
  let(:on_batch) do
    collected = batches
    ->(batch) { collected << batch }
  end
  let(:limits)   { {} }
  let(:urls)     { [ "https://lists.example/socks5.txt" ] }
  let(:received) { batches.flatten }

  def ip(i)
    "10.#{i / 65_536}.#{(i / 256) % 256}.#{i % 256}"
  end

  def stub_list(url, body)
    stub_request(:get, url).to_return(status: 200, body:)
  end

  context "with plain host:port and scheme-prefixed lines" do
    let(:urls) { [ "https://lists.example/socks5.txt", "https://lists.example/https.txt" ] }

    before do
      stub_list(urls[0], "# comment\n1.1.1.1:1080\n\nsocks5a://2.2.2.2:1080\n1.1.1.1:1080\n")
      stub_list(urls[1], "3.3.3.3:8080\nhttps://4.4.4.4:3128\nnot a proxy\n")
    end

    it "infers and normalizes the protocol and drops duplicates" do
      expect(perform.model).to eq(4)
      expect(received).to contain_exactly(
        { host: "1.1.1.1", port: 1080, protocol: "socks5" },
        { host: "2.2.2.2", port: 1080, protocol: "socks5h" },
        { host: "3.3.3.3", port: 8080, protocol: "http" },
        { host: "4.4.4.4", port: 3128, protocol: "http" }
      )
    end
  end

  context "with a list larger than one batch" do
    let(:count) { described_class::BATCH_SIZE * 2 + 7 }

    before { stub_list(urls.first, Array.new(count) { |i| "#{ip(i)}:1080" }.join("\n")) }

    it "streams the candidates in BATCH_SIZE slices" do
      perform
      expect(batches.map(&:size)).to eq([ described_class::BATCH_SIZE, described_class::BATCH_SIZE, 7 ])
    end
  end

  context "with max_candidates" do
    let(:limits) { { max_candidates: 30 } }

    before { stub_list(urls.first, Array.new(100) { |i| "#{ip(i)}:1080" }.join("\n")) }

    it "stops at exactly the cap" do
      expect(perform.model).to eq(30)
      expect(received.size).to eq(30)
    end
  end

  context "with max_per_list" do
    let(:limits) { { max_per_list: 200 } }

    before { stub_list(urls.first, Array.new(2_000) { |i| "#{ip(i)}:1080" }.join("\n")) }

    it "samples across the whole list instead of taking its first lines" do
      perform
      indexes = received.map { |p| p[:host].split(".").map(&:to_i).then { |(_, a, b, c)| a * 65_536 + b * 256 + c } }

      expect(received.size).to be_between(100, 300) # Binomial(2000, 0.1): mean 200, sd ≈ 13
      expect(indexes.max).to be > 1_000
    end
  end

  context "with catalog links" do
    let(:urls)       { [ "https://lists.example/root.txt" ] }
    let(:child)      { "https://lists.example/child.txt" }
    let(:grandchild) { "https://lists.example/grandchild.txt" }

    before do
      stub_list(urls.first, "#{child}\n1.1.1.1:8080\n")
      stub_list(child, "#{grandchild}\n2.2.2.2:8080\n")
      stub_list(grandchild, "3.3.3.3:8080\n")
    end

    it "follows them only down to max_depth" do
      described_class.call(on_batch:, urls:, max_depth: 1)

      expect(received.map { |p| p[:host] }).to contain_exactly("1.1.1.1", "2.2.2.2")
      expect(a_request(:get, grandchild)).not_to have_been_made
    end

    it "fetches at most max_urls lists" do
      described_class.call(on_batch:, urls:, max_depth: 5, max_urls: 2)

      expect(a_request(:get, grandchild)).not_to have_been_made
    end
  end

  context "when a list cannot be fetched" do
    let(:urls) { [ "https://lists.example/http.txt", "https://lists.example/down.txt" ] }

    before do
      stub_list(urls[0], "1.1.1.1:8080\n")
      stub_request(:get, urls[1]).to_return(status: 503)
    end

    it "keeps the candidates of the other lists" do
      expect(perform.model).to eq(1)
    end
  end

  context "when writing a batch fails" do
    let(:on_batch) do
      collected = batches
      calls     = 0
      lambda do |batch|
        calls += 1
        raise ActiveRecord::ConnectionNotEstablished, "db down" if calls == 1

        collected << batch
      end
    end

    before do
      stub_list(urls.first, Array.new(described_class::BATCH_SIZE + 3) { |i| "#{ip(i)}:1080" }.join("\n"))
    end

    it "re-raises after handing the unwritten batch to the final flush" do
      expect { perform }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(received.size).to eq(described_class::BATCH_SIZE)
    end
  end
end
