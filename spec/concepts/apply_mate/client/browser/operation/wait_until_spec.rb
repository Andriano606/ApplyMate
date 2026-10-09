# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Operation::WaitUntil do
  let(:clock) { ApplyMate::Client::Browser::Clock }
  let(:now) { [ 0.0 ] }
  let(:remaining_ms) { 60_000 }
  let(:driver) { instance_double(ApplyMate::Client::Browser::Driver::Playwright, remaining_ms:) }

  before do
    allow(clock).to receive(:now_ms) { now.first }
    allow(clock).to receive(:sleep_ms) { |milliseconds| now[0] += milliseconds }
  end

  def wait(timeout_ms, &condition)
    described_class.call(driver:, timeout_ms:, condition:).model
  end

  it 'returns the first truthy value of the condition' do
    answers = [ nil, false, 'ready' ]

    expect(wait(5_000) { answers.shift }).to eq('ready')
    expect(now.first).to eq(500.0) # two polls of 250 ms
  end

  it 'gives up with false after the timeout when the world stays broken' do
    calls = 0
    expect(wait(1_000) { calls += 1 and nil }).to be(false)

    expect(now.first).to eq(1_000.0)
    expect(calls).to eq(5)
  end

  context 'when the deadline is closer than the timeout' do
    let(:remaining_ms) { 300 }

    it 'stops at the deadline' do
      expect(wait(10_000) { false }).to be(false)
      expect(now.first).to eq(300.0)
    end
  end

  it 'treats TargetNotFound and Playwright errors as "not yet" and lets everything else through' do
    answers = [ -> { raise ApplyMate::Client::Browser::TargetNotFound, ApplyMate::Client::Browser::Target.css('x') },
                -> { raise Playwright::Error.new(message: 'navigating') }, -> { :done } ]
    expect(wait(5_000) { answers.shift.call }).to eq(:done)

    expect { wait(5_000) { raise ApplyMate::Client::Browser::Crashed, 'gone' } }
      .to raise_error(ApplyMate::Client::Browser::Crashed)
  end
end
