# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::WaitReady do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:top_url) { 'https://preply.com/en/careers/apply?ashby_jid=x' }
  let(:embed_url) { 'https://jobs.ashbyhq.com/preply/x/application?embed=js' }
  let(:frame_path) { [ { 'selector' => 'iframe#ashby_embed_iframe' } ] }
  let(:snapshot) do
    FakeSession::EMPTY_SNAPSHOT.with(frames: [ { 'url' => top_url, 'frame_path' => [] }, { 'url' => embed_url, 'frame_path' => frame_path } ])
  end
  let(:session) { FakeSession.new(html: '', final_url: top_url, snapshot:) }
  let(:readiness) { nil }
  let(:root_selector) { nil }
  let(:platform_class) do
    readiness_value = readiness
    selector = root_selector
    Class.new(Apply::Platform::Base) do
      define_singleton_method(:key) { 'spec_form' }
      define_method(:readiness) { readiness_value }
      define_method(:form_root_selector) { selector }
    end
  end

  def wait(timeout: 30)
    described_class.call(ctx:, timeout:).model
  end

  before do
    match = Apply::Operation::Engine::Detect::Match.new(key: 'spec_form', confidence: 0.9, captures: {}, frame_path: nil,
                                                        from_alias: false, probable: nil)
    ctx.scratch.match = match
    ctx.scratch.platform = platform_class.new(ctx:, match:)
    ctx.open_scope!(:survey, session, 5.minutes.from_now)
  end

  describe '.readiness_of' do
    it 'defaults to three visible fields in the form root, or in body' do
      expect(described_class.readiness_of(nil)).to have_attributes(kind: :visible_fields, min: 3, root: 'body')
      expect(described_class.readiness_of(ctx.platform)).to have_attributes(kind: :visible_fields, min: 3, root: 'body')
    end

    context 'with a form root selector' do
      let(:root_selector) { '#form' }

      it 'waits inside it' do
        expect(described_class.readiness_of(ctx.platform)).to have_attributes(root: '#form')
      end
    end
  end

  it 'returns the root target of the top frame when it is ready there' do
    expect(wait).to eq(ApplyMate::Client::Browser::Target.css('body'))
    expect(session.calls_of(:ready?).first).to eq([ ApplyMate::Client::Browser::Target.css('body'), { timeout: 0, min_fields: 3 } ])
    expect(session.calls_of(:wait_until)).to eq([ [ { timeout: 30 } ] ])
  end

  context 'when the form lives in a cross-origin iframe (schema keys mode)' do
    let(:readiness) do
      Apply::Platform::Base::Readiness.schema_keys(keys: %w[a b c], attr: 'data-field-path', root: '#form[role="tabpanel"]')
    end

    before do
      allow(session).to receive(:frames).and_return([ { 'url' => top_url, 'name' => '' }, { 'url' => 'about:blank', 'name' => '' },
                                                      { 'url' => embed_url, 'name' => '' } ])
      allow(session).to receive(:ready?) { |target, **| target.frame_path.any? }
    end

    it 'polls each http frame in keys mode and returns the root with the frame path from the snapshot' do
      expect(wait).to eq(ApplyMate::Client::Browser::Target.css('#form[role="tabpanel"]', frame_path:))
      expect(session).to have_received(:ready?).with(
        ApplyMate::Client::Browser::Target.css('#form[role="tabpanel"]', frame_path: [ { 'url_contains' => embed_url } ]),
        timeout: 0, keys: %w[a b c], attr: 'data-field-path', ratio: 0.8, key_prefix: nil
      )
      expect(session).to have_received(:ready?).twice # the top frame and the embed; about:blank is skipped
    end
  end

  it 'never polls more than MAX_FRAMES frames' do
    frames = Array.new(30) { |index| { 'url' => "https://example.com/#{index}", 'name' => '' } }
    allow(session).to receive(:frames).and_return(frames)
    allow(session).to receive(:ready?).and_return(false)

    wait
    expect(session).to have_received(:ready?).exactly(ApplyMate::Client::Browser::Driver::Playwright::MAX_FRAMES).times
  end

  it 'is nil when no frame gets ready within the timeout' do
    allow(session).to receive(:ready?).and_return(false)

    expect(wait(timeout: 5)).to be_nil
    expect(session.calls_of(:wait_until)).to eq([ [ { timeout: 5 } ] ])
  end
end
