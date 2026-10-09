# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Ai::Client::GeminiScraping do
  subject(:client) { described_class.new(api_key: nil, host: nil, model: nil) }

  let(:browser) { instance_double(Ferrum::Browser, quit: nil) }

  before do
    allow(Ferrum::Browser).to receive(:new).and_return(browser)
  end

  describe '.capabilities' do
    it 'declares browser_backed only' do
      expect(described_class.capabilities).to eq(%i[browser_backed])
      expect(described_class.supports?(:json_schema)).to be(false)
    end
  end

  it 'does not launch a browser when built' do
    client

    expect(Ferrum::Browser).not_to have_received(:new)
  end

  it 'is slow: every kind takes CALL_SECONDS (setup + the answer wait)' do
    expect(described_class.call_seconds(:navigate)).to eq(described_class::SETUP_SECONDS + described_class::RESPONSE_TIMEOUT)
  end

  # AiHandler gives a request the client's own latency as its timeout.
  def request_for(kind:, text:, timeout: described_class::CALL_SECONDS, **options)
    ApplyMate::Ai::Request.for(kind:, text:, timeout:, **options)
  end

  describe '#complete' do
    it 'types the flattened system + messages prompt and wraps the answer with Usage::UNKNOWN' do
      allow(client).to receive(:scrape_answer).and_return('Привіт!')
      request = request_for(kind: :answers, text: 'Say hello', system: 'Answer in Ukrainian')

      response = client.complete(request)

      expect(client).to have_received(:scrape_answer).with("Answer in Ukrainian\n\nSay hello", kind_of(Float))
      expect(response).to eq(ApplyMate::Ai::Response.new(text: 'Привіт!', usage: ApplyMate::Ai::Usage::UNKNOWN))
    end

    it 'omits a nil system prompt' do
      allow(client).to receive(:scrape_answer).and_return('ok')

      client.complete(request_for(kind: :verify, text: 'Only text'))

      expect(client).to have_received(:scrape_answer).with('Only text', kind_of(Float))
    end

    it 'raises CapabilityMissing on images before any browser starts' do
      request = ApplyMate::Ai::Request.for(kind: :verify, text: 'x', images: [ { mime_type: 'image/png', data: 'aGk=' } ])

      expect { client.complete(request) }.to raise_error(ApplyMate::Ai::Client::Base::CapabilityMissing, /vision/)
      expect(Ferrum::Browser).not_to have_received(:new)
    end

    it 'quits the browser it launched when scraping fails' do
      allow(browser).to receive(:contexts).and_raise(Ferrum::Error, 'cdp gone')

      expect { client.complete(request_for(kind: :verify, text: 'x')) }
        .to raise_error(Ferrum::Error, 'cdp gone')
      expect(browser).to have_received(:quit)
      expect(ApplyMate::Client::LocalChrome::SLOT.available_permits).to eq(1) # released after the failure
    end
  end

  describe 'the process-wide local Chrome slot' do
    let(:slot) { ApplyMate::Client::LocalChrome::SLOT }

    after { expect(slot.available_permits).to eq(1) }

    it 'runs at most one local Chrome at a time across threads' do
      running = Concurrent::AtomicFixnum.new(0)
      peak = Concurrent::AtomicFixnum.new(0)
      clients = Array.new(3) { described_class.new }
      clients.each do |each_client|
        allow(each_client).to receive(:scrape_answer) do
          peak.update { |value| [ value, running.increment ].max }
          sleep 0.05
          running.decrement
          'ok'
        end
      end

      clients.map { |each_client| Thread.new { each_client.complete(request_for(kind: :navigate, text: 'x')) } }.each(&:join)

      expect(peak.value).to eq(1)
      clients.each { |each_client| expect(each_client).to have_received(:scrape_answer).once }
    end

    it 'raises Busy without launching a browser when the slot stays taken past the call budget' do
      slot.acquire
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        expect { client.complete(request_for(kind: :navigate, text: 'x', timeout: described_class::SETUP_SECONDS + 0.2)) }
          .to raise_error(ApplyMate::Client::LocalChrome::Busy, /slot/)
      ensure
        slot.release
      end

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(Ferrum::Browser).not_to have_received(:new)
    end

    it 'raises DeadlineTooShort (not Busy) at once for a budget shorter than the browser setup, slot free' do
      allow(slot).to receive(:try_acquire).and_call_original

      expect { client.complete(request_for(kind: :verify, text: 'x', timeout: described_class::SETUP_SECONDS - 1)) }
        .to raise_error(ApplyMate::Ai::Client::Base::DeadlineTooShort, /needs more than #{described_class::SETUP_SECONDS} s/)
      expect(slot).not_to have_received(:try_acquire)
      expect(Ferrum::Browser).not_to have_received(:new)
    end

    it 'shares the slot with the Grover render: a call waits while a CV renders' do
      allow(client).to receive(:scrape_answer).and_return('ok')
      rendering = Concurrent::Event.new
      release = Concurrent::Event.new
      render = Thread.new { ApplyMate::Client::LocalChrome.hold(wait: 1) { rendering.set; release.wait(5) } }
      rendering.wait(5)

      call = Thread.new { client.complete(request_for(kind: :navigate, text: 'x')) }
      sleep 0.1
      expect(client).not_to have_received(:scrape_answer)

      release.set
      expect(call.value.text).to eq('ok')
      render.join
    end
  end
end
