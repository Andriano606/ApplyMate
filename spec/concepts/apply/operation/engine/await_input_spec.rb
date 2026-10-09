# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::AwaitInput do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:code) { SecureRandom.random_number(1_000_000).to_s.rjust(6, '0') }
  let(:snapshot) do
    build_snapshot(
      frames: [ { outline: [ 'p Enter the verification code we sent to your email.' ] } ],
      elements: [ snapshot_element(role: 'textbox', name: 'Code', type: 'text', id: 'code'),
                  snapshot_element(role: 'button', name: 'Verify', submit_like: true, id: 'verify') ]
    )
  end
  let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.example.com/apply', snapshot:) }
  let(:field_element) { snapshot.elements.find { |element| element['name'] == 'Code' } }
  let(:frame) { snapshot.frames.first }

  def await
    described_class.call(ctx:, kind: 'email_code', field_element:, frame:).model
  end

  def answer(value = code)
    Apply.where(id: apply.id).update_all(input_response: { 'code' => value, 'at' => Time.current.iso8601 })
  end

  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    ctx.open_scope!(:survey, session, 20.minutes.from_now)
  end

  context 'when the user types the code' do
    before do
      polls = 0
      allow_any_instance_of(described_class).to receive(:sleep) do |_op, seconds| # rubocop:disable RSpec/AnyInstance
        polls += 1
        expect(seconds).to eq(described_class::POLL_INTERVAL)
        expect(apply.reload).to have_attributes(stage: 'awaiting_input', input_response: nil)
        answer if polls == 2
      end
    end

    it 'parks in awaiting_input, enters the code with read-back, confirms and clears the request' do
      expect(await).to be(true)

      expect(session.calls_of(:fill)).to eq([ [ field_element['target'], code ] ])
      expect(session.calls_of(:click)).to eq([ [ snapshot.elements.find { |element| element['name'] == 'Verify' }['target'] ] ])
      expect(session.calls_of(:settle).last).to eq([ :submit ])
      expect(apply.reload).to have_attributes(input_request: nil, input_response: nil, stage: 'submit')
    end

    it 'publishes the request with its kind and expiry before waiting' do
      seen = nil
      allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) { |row| seen ||= row.input_request }

      await

      expect(seen).to include('kind' => 'email_code')
      expect(Time.zone.parse(seen['expires_at']) - Time.zone.parse(seen['requested_at'])).to be_within(1).of(described_class::MAX_WAIT)
    end

    it 'never puts the code into the trace' do
      await

      expect(ctx.scratch.trace.to_json).not_to include(code)
      expect(ctx.scratch.trace.last).to include('event' => 'email_code_entered')
    end

    it 'presses Enter when the frame has no single submit button' do
      session.show(build_snapshot(frames: [ frame.symbolize_keys.slice(:outline) ], elements: [ snapshot_element(role: 'textbox', name: 'Code', id: 'code') ]))

      await

      expect(session.calls_of(:press)).to eq([ [ field_element['target'], 'Enter' ] ])
      expect(session.calls_of(:click)).to be_empty
    end

    it 'halts when the site does not take the code' do
      session.on(:fill) { |target, _text| session.instance_variable_get(:@filled)[target] = 'garbled' }
      allow(session).to receive(:probe).and_return({ 'tag' => 'input', 'value' => 'x', 'displayed' => 'x', 'invalid' => false })

      expect { await }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :email_code, detail: 'code not accepted')
      }
    end
  end

  context 'when nobody answers' do
    before do
      allow_any_instance_of(described_class).to receive(:sleep) { travel(2.minutes) } # rubocop:disable RSpec/AnyInstance
    end

    it 'halts email_code after MAX_WAIT with the request cleared and the stage back on submit' do
      expect { await }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:email_code) }

      expect(apply.reload).to have_attributes(input_request: nil, stage: 'submit')
      expect(session.calls_of(:fill)).to be_empty
    end
  end

  context 'when the code arrives after the last poll, before the request is closed' do
    before do
      allow_any_instance_of(described_class).to receive(:sleep) do # rubocop:disable RSpec/AnyInstance
        travel(2.minutes)
        answer if Time.current >= Time.zone.parse(apply.reload.input_request['expires_at'])
      end
    end

    it 'uses the stored code instead of throwing it away' do
      expect(await).to be(true)

      expect(session.calls_of(:fill)).to eq([ [ field_element['target'], code ] ])
      expect(apply.reload).to have_attributes(input_request: nil, input_response: nil, stage: 'submit')
    end
  end

  it 'halts without waiting when the run has no time left' do
    short = ctx.with(deadline_at: (described_class::RESERVE - 1).seconds.from_now)

    expect { described_class.call(ctx: short, kind: 'email_code', field_element:, frame:) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
      expect(halt).to have_attributes(code: :email_code, detail: 'no time to wait')
    }
    expect(apply.reload.input_request).to be_nil
  end

  it 'is fenced when the run_token rotates while waiting' do
    allow_any_instance_of(described_class).to receive(:sleep) do # rubocop:disable RSpec/AnyInstance
      rotate_run_token!(apply)
      travel(2.minutes)
    end

    expect { await }.to raise_error(Apply::Operation::Engine::Fenced)
  end

  it 'ignores a code stored under another run_token' do
    other = create(:apply)
    other.update_columns(input_response: { 'code' => code })
    allow_any_instance_of(described_class).to receive(:sleep) { travel(2.minutes) } # rubocop:disable RSpec/AnyInstance

    expect { await }.to raise_error(Apply::Operation::Engine::Halt)
  end
end
