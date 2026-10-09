# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Operation::WaitQuiet do
  let(:clock) { ApplyMate::Client::Browser::Clock }
  let(:now) { [ 0.0 ] }
  # busy: in-flight count per poll (the last value repeats); last_event_at: ms of the last network event.
  let(:tracker_class) do
    Struct.new(:busy, :last_event_at, :ignore_older) do
      def pending(ignore_older_ms:)
        self.ignore_older = ignore_older_ms
        busy.size > 1 ? busy.shift : busy.first
      end
    end
  end
  let(:tracker) { tracker_class.new([ 0 ], -Float::INFINITY) }
  let(:deadline) { 1.minute.from_now }

  before do
    allow(clock).to receive(:now_ms) { now.first }
    allow(clock).to receive(:sleep_ms) { |milliseconds| now[0] += milliseconds }
  end

  def wait(profile = :click)
    described_class.call(tracker:, profile:, deadline:).model
  end

  it 'waits at least min ms even when the network is already quiet' do
    expect(wait(:click)).to eq(quiet: true, ms: 150.0)
    expect(wait(:submit)).to eq(quiet: true, ms: 500.0)
  end

  it 'waits until nothing is in flight and the last event is quiet ms old' do
    tracker.busy = [ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0 ] # in flight for the first 10 polls (500 ms)
    tracker.last_event_at = 480.0                      # the request finished at 480 ms

    expect(wait(:click)).to eq(quiet: true, ms: 800.0) # 480 + quiet 300, rounded up to the 50 ms poll
  end

  it 'gives up at max ms when the network never settles' do
    tracker.busy = [ 1 ]

    expect(wait(:key)).to eq(quiet: false, ms: 1_500.0)
    expect(tracker.ignore_older).to eq(3_000)
  end

  it 'clamps max to the time left before the deadline' do
    tracker.busy = [ 1 ]
    travel_to(Time.zone.parse('2026-10-07 12:00:00')) do
      result = described_class.call(tracker:, profile: :submit, deadline: Time.current + 0.4).model

      expect(result).to eq(quiet: false, ms: 400.0)
    end
  end

  it 'returns at once when the deadline has passed' do
    expect(described_class.call(tracker:, profile: :file, deadline: 1.second.ago).model).to eq(quiet: false, ms: 0.0)
    expect(clock).not_to have_received(:sleep_ms)
  end

  it 'rejects an unknown profile' do
    expect { wait(:scroll) }.to raise_error(KeyError)
  end
end
