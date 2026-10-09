# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::CaptureArtifact do
  subject(:capture) { described_class.call(ctx:, step_record:, label:) }

  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:step_record) do
    ApplyStep.create!(apply:, attempt: ctx.attempt, key: 'fill', stage: 'fill', position: 0, state: :running, started_at: Time.current)
  end
  let(:label) { :failure }
  let(:html) { "<html><body onload=\"boot()\">write to #{apply.user.email} \nCookie: secret\nbody<script>location.reload()</script></body></html>" }
  let(:session) { FakeSession.new(html:, final_url: 'https://example.com/') }

  def names
    step_record.reload.artifacts.map { |artifact| artifact.filename.to_s }
  end

  context 'with an open session' do
    before { ctx.open_scope!(:survey, session, 1.minute.from_now) }

    it 'attaches a masked screenshot and the redacted HTML of the frame for a failure' do
      expect(capture.model).to eq(2)

      expect(names).to contain_exactly('failure.png', 'failure_f0.html')
      expect(session.calls).to include([ :screenshot, { full_page: false, mask_fillable: true } ])
      stored = step_record.artifacts.find { |artifact| artifact.filename.to_s == 'failure_f0.html' }.download
      expect(stored).to include('{{fact.email}}')
      expect(stored).not_to include(apply.user.email)
      expect(stored).not_to include('Cookie: secret')
      expect(stored).not_to include('<script', 'onload')
      expect(stored).to include('Content-Security-Policy')
      expect(ctx.scratch.artifacts_count).to eq(2)
    end

    it 'only takes a screenshot for another label' do
      described_class.call(ctx:, step_record:, label: :before_submit)

      expect(names).to eq([ 'before_submit.png' ])
      expect(session.calls_of(:html)).to be_empty
    end

    it 'truncates each frame HTML to 512 KB' do
      big = FakeSession.new(html: 'x' * 600.kilobytes, final_url: 'https://example.com/')
      ctx.open_scope!(:survey, big, 1.minute.from_now)

      capture

      stored = step_record.reload.artifacts.find { |artifact| artifact.filename.to_s == 'failure_f0.html' }
      expect(stored.byte_size).to eq(described_class::HTML_LIMIT)
    end

    it 'attaches one HTML per frame, picking child frames by url' do
      allow(session).to receive(:frames).and_return([ { 'url' => 'https://example.com/', 'name' => '' },
                                                      { 'url' => 'https://embed.example/form', 'name' => 'f' } ])

      capture

      expect(names).to contain_exactly('failure.png', 'failure_f0.html', 'failure_f1.html')
      expect(session.calls_of(:html)).to eq([ [ { frame_path: [] } ], [ { frame_path: [ { 'url_contains' => 'https://embed.example/form' } ] } ] ])
    end

    it 'stops at ApplyStep::MAX_ARTIFACTS_PER_ATTEMPT per attempt' do
      ctx.scratch.artifacts_count = ApplyStep::MAX_ARTIFACTS_PER_ATTEMPT - 1

      expect(capture.model).to eq(1)
      expect(ctx.scratch.artifacts_count).to eq(ApplyStep::MAX_ARTIFACTS_PER_ATTEMPT)
      expect(names).to eq([ 'failure.png' ])

      expect(described_class.call(ctx:, step_record:, label: :again).model).to eq(0)
    end

    it 'never raises: a broken session is logged and reported' do
      allow(session).to receive(:screenshot).and_raise(ApplyMate::Client::Browser::Crashed, 'gone')
      allow(Rails.error).to receive(:report)

      expect(capture).to be_success
      expect(Rails.error).to have_received(:report).with(an_instance_of(ApplyMate::Client::Browser::Crashed), hash_including(:context))
      expect(names).to include('failure_f0.html')
    end
  end

  it 'does nothing without an open session' do
    expect(capture.model).to eq(0)
    expect(names).to be_empty
  end
end
