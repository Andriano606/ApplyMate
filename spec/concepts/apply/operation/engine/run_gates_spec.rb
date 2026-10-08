# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::RunGates do
  let(:ctx) { engine_context(create(:apply)) }
  let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.example.com', snapshot:) }
  let(:snapshot) do
    ApplyMate::Client::Browser::Snapshot.new(
      frames: [ { 'url' => 'https://jobs.example.com', 'captcha' => [], 'password_fields' => 0 } ],
      elements: [ { 'role' => 'button', 'name' => 'Reject all', 'visible' => true, 'disabled' => false,
                    'target' => ApplyMate::Client::Browser::Target.css('#reject') } ],
      evidence: { frame_urls: [ 'https://jobs.example.com' ], script_srcs: [], iframe_srcs: [], dom_markers: {} },
      digest: 'x'
    )
  end

  def evidence(*urls)
    Apply::Operation::Engine::Detect::Evidence.build(current_urls: urls, hops: urls)
  end

  it 'runs the default gates before detection and lets a Halt through' do
    expect { described_class.call(ctx:, event: :http_resolved, evidence: evidence('https://t.me/hr')) }
      .to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:external_messenger) }
  end

  it 'returns the gates that resolved something, deriving evidence from the snapshot' do
    ctx.session = session

    expect(described_class.call(ctx:, event: :after_goto, snapshot:).model).to eq([ 'Apply::Gate::CookieConsent' ])
  end

  it 'runs only the gates listening to the event' do
    ctx.session = session

    expect(described_class.call(ctx:, event: :before_submit, snapshot:).model).to eq([])
    expect(session.calls_of(:click)).to be_empty
  end

  it 'honours the adopted platform gate list' do
    skipping = Class.new(Apply::Platform::Base) { skipped_gates 'Apply::Gate::ExternalMessenger' }
    ctx.scratch.platform = skipping.new(ctx:, match: Apply::Operation::Engine::Detect::Match.generic)

    expect(described_class.call(ctx:, event: :http_resolved, evidence: evidence('https://t.me/hr')).model).to eq([])
  end

  it 'rejects unknown events and a call without evidence' do
    expect { described_class.call(ctx:, event: :whenever, evidence: evidence) }.to raise_error(ArgumentError)
    expect { described_class.call(ctx:, event: :after_goto) }.to raise_error(ArgumentError)
  end
end
