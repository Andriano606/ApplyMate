# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Recipe::Op::WaitFor do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:url) { 'https://acme.example/jobs/1/apply' }
  let(:frame_path) { [ { 'selector' => 'iframe#embed' } ] }
  let(:missing) { [] }
  let(:session) { FakeSession.new(html: '', final_url: url, missing:) }
  let(:op) { described_class.new(root: 'form#apply', frame_path:, min_fields: 3) }

  before { ctx.open_scope!(:survey, session, 5.minutes.from_now) }

  it 'round-trips through its hash (frame_path defaults to the top frame)' do
    expect(Apply::Recipe::Op::Base.parse!(JSON.parse(op.to_h.to_json)).to_h)
      .to eq('op' => 'wait_for', 'root' => 'form#apply', 'frame_path' => frame_path, 'min_fields' => 3)
    expect(Apply::Recipe::Op::Base.parse!('op' => 'wait_for', 'root' => 'form', 'min_fields' => 1).frame_path).to eq([])
  end

  it 'waits for the root to hold min_fields and makes it the form root' do
    op.perform!(ctx)

    root = ApplyMate::Client::Browser::Target.css('form#apply', frame_path:)
    expect(session.calls_of(:ready?)).to eq([ [ root, { timeout: described_class::READY_TIMEOUT, min_fields: 3 } ] ])
    expect(ctx).to have_attributes(form_root: root, form_url: url)
  end

  it 'clamps the wait to the time left' do
    ctx.scratch.scope_deadline = 4.seconds.from_now
    op.perform!(ctx)

    expect(session.calls_of(:ready?).sole.last[:timeout]).to be <= 4
  end

  context 'when the form never gets ready' do
    let(:missing) { [ 'form#apply' ] }

    it 'is drift and leaves the form root unset' do
      expect { op.perform!(ctx) }.to raise_error(Apply::Operation::Recipe::Drift) { |drift| expect(drift.op).to be(op) }
      expect(ctx.form_root).to be_nil
    end
  end
end
