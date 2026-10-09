# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::LocalChrome do
  let(:slot) { described_class::SLOT }

  after { expect(slot.available_permits).to eq(1) }

  it 'lets at most one holder run at a time across threads' do
    running = Concurrent::AtomicFixnum.new(0)
    peak = Concurrent::AtomicFixnum.new(0)

    Array.new(3) do
      Thread.new do
        described_class.hold(wait: 5) do
          peak.update { |value| [ value, running.increment ].max }
          sleep 0.05
          running.decrement
        end
      end
    end.each(&:join)

    expect(peak.value).to eq(1)
  end

  it 'returns the block value and releases the slot when the block raises' do
    expect(described_class.hold(wait: 0) { :done }).to eq(:done)
    expect { described_class.hold(wait: 0) { raise ArgumentError, 'boom' } }.to raise_error(ArgumentError, 'boom')
  end

  it 'raises Busy after the wait when the slot stays taken, without running the block' do
    slot.acquire
    ran = false
    begin
      expect { described_class.hold(wait: 0.1) { ran = true } }.to raise_error(described_class::Busy, /slot stayed taken/)
    ensure
      slot.release
    end

    expect(ran).to be(false)
  end

  it 'does not wait at all for a negative wait' do
    allow(slot).to receive(:try_acquire).and_call_original

    expect { described_class.hold(wait: -1) { nil } }.to raise_error(described_class::Busy)
    expect(slot).not_to have_received(:try_acquire)
  end
end
