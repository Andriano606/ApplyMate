# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::ReachForm do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:canonical) { "https://jobs.ashbyhq.com/preply/#{jid}/application" }
  let(:session) { FakeSession.new(html: '', final_url: canonical) }
  let(:form_root) { ApplyMate::Client::Browser::Target.css('#form[role="tabpanel"]') }
  let(:unwrap) { { 'op' => 'unwrap', 'url_template' => '{canonical_form_url}' } }

  def adopt_ashby(context)
    context.adopt_match!(Apply::Operation::Engine::Detect::Match.new(
      key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => jid }, frame_path: nil, from_alias: false,
      probable: nil
    ))
  end

  before do
    adopt_ashby(ctx)
    ctx.open_scope!(:survey, session, 5.minutes.from_now)
    allow(session).to receive(:current_url).and_return('about:blank', canonical)
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to be_present
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to be_present
  end

  it 'reaches the form and persists the navigation and the form URL' do
    result = described_class.call(ctx:)

    expect(session.calls_of(:goto)).to eq([ [ canonical ] ])
    expect(result[:step_result]).to eq('navigation' => [ unwrap ], 'form_url' => canonical,
                                       'form_root' => form_root.to_h.deep_stringify_keys, 'platform' => 'ashby', 'schema' => 0)
    expect(apply.reload).to have_attributes(navigation: [ unwrap ], form_url: canonical, platform: 'ashby',
                                            apply_key: "ashby:preply:#{jid}")
    expect(ctx).to have_attributes(form_url: canonical, form_root:)
  end

  it 'halts not_a_form when the form never gets ready' do
    allow(session).to receive(:ready?).and_return(false)

    expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Halt, /not_a_form/)
    expect(apply.reload.navigation).to be_nil
  end

  it 'restores the form URL and the form root a later scope needs' do
    result = described_class.call(ctx:)[:step_result]
    fresh = Apply::Operation::Engine::Context.new(**ctx.to_h, scratch: Apply::Operation::Engine::Context::Scratch.new)

    described_class.restore(fresh, JSON.parse(result.to_json))

    expect(fresh).to have_attributes(form_url: canonical, form_root:)
  end

  context 'when the job id has a digit run Redact reads as a phone number' do
    let(:jid) { '4a1b2c3d-1234-5678-9012-345678901abc' }

    it 'restores the form URL from applies.form_url, not from the redacted step result' do
      result = described_class.call(ctx:)[:step_result]
      redacted = Apply::Operation::Engine::RedactTree.call(value: JSON.parse(result.to_json), apply:).model
      fresh = Apply::Operation::Engine::Context.new(**ctx.to_h, apply: apply.reload, scratch: Apply::Operation::Engine::Context::Scratch.new)

      described_class.restore(fresh, redacted)

      expect(redacted['form_url']).to include('{{phone}}')
      expect(fresh.form_url).to eq(canonical)
    end
  end

  context 'when the landing page identifies a platform the HTTP level only found probable (generic -> ashby)' do
    let(:preply) { "https://preply.com/en/careers/apply?ashby_jid=#{jid}" }
    let(:embed) { "https://jobs.ashbyhq.com/preply/#{jid}?embed=js" }
    let(:frame_urls) { [ preply, embed ] }
    let(:snapshot) do
      FakeSession::EMPTY_SNAPSHOT.with(evidence: { frame_urls:, script_srcs: [], iframe_srcs: frame_urls.drop(1), dom_markers: {} })
    end
    let(:session) { FakeSession.new(html: '', final_url: canonical, snapshot:) }
    let(:posting) { ApplyMate::Client::Response.new(file_fixture('apply_engine/ashby/api_job_posting.json').read, {}, 200, nil) }
    let(:landing) { { 'op' => 'goto', 'url_template' => '{landing_url}' } }

    def generic_ctx(context)
      context.evidence = Apply::Operation::Engine::Detect::Evidence.build(current_urls: [ preply ], hops: [ 'https://dou.ua/goto/vacancy/?id=1', preply ])
      context.redetect!(context.evidence)
    end

    before do
      allow(session).to receive(:current_url) { session.calls_of(:goto).last&.first || 'about:blank' }
      allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
      allow(ctx.http).to receive(:post).and_return(posting)
      ctx.scratch.match = nil
      generic_ctx(ctx)
      apply.update_columns(platform: 'generic', platform_match: ctx.match.to_h, landing_url: preply)
    end

    it 'lands on the careers page, reads the schema, unwraps the canonical form and persists the new detection' do
      result = described_class.call(ctx:)[:step_result]

      expect(session.calls_of(:goto)).to eq([ [ preply ], [ canonical ] ])
      expect(result).to include('navigation' => [ landing, unwrap ], 'platform' => 'ashby', 'schema' => 15)
      expect(apply.reload).to have_attributes(platform: 'ashby', apply_key: "ashby:preply:#{jid}", form_url: canonical,
                                              navigation: [ landing, unwrap ])
      expect(apply.platform_match).to include('key' => 'ashby', 'captures' => { 'slug' => 'preply', 'jid' => jid })
    end

    it 'restores the switched platform and the schema it read on a later attempt (the digest matches again)' do
      digest = described_class.input_digest(ctx)
      result = described_class.call(ctx:)[:step_result]
      apply.update!(fields: ctx.schema.map(&:to_h)) # what DiscoverFields persists (schema_api fields)
      fresh = Apply::Operation::Engine::Context.new(**ctx.to_h, apply: apply.reload, scratch: Apply::Operation::Engine::Context::Scratch.fresh)
      generic_ctx(fresh)

      expect(described_class.input_digest(fresh)).to eq(digest)
      described_class.restore(fresh, Apply::Operation::Engine::RedactTree.call(value: JSON.parse(result.to_json), apply:).model)

      expect(fresh.match).to have_attributes(key: 'ashby', captures: { 'slug' => 'preply', 'jid' => jid })
      expect(fresh.platform).to be_a(Apply::Platform::Ashby)
      expect(fresh.schema.map(&:id)).to match_array(ctx.schema.map(&:id))
      expect(fresh).to have_attributes(form_url: canonical, form_root:)
    end

    it 'halts already_applied when the now known posting was submitted by another apply' do
      create(:apply, :completed, user: apply.user, apply_key: "ashby:preply:#{jid}")

      expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt.code).to eq(:already_applied)
      }
    end

    context 'when the landing page shows no known platform' do
      let(:frame_urls) { [ preply ] }

      it 'succeeds without a form and persists nothing but leaves the platform generic (the legacy path runs)' do
        result = described_class.call(ctx:)[:step_result]

        expect(result).to include('navigation' => nil, 'form_url' => nil, 'platform' => 'generic', 'schema' => 0)
        expect(session.calls_of(:goto)).to eq([ [ preply ] ])
        expect(apply.reload).to have_attributes(platform: 'generic', navigation: nil, form_url: nil)
        expect(ctx.platform_known?).to be(false)
        expect(ctx.scratch.trace.pluck('event')).to include('landed', 'platform_unknown')
      end
    end
  end

  describe '.input_digest' do
    it 'is stable for the same match and schema' do
      expect(described_class.input_digest(ctx)).to eq(described_class.input_digest(ctx))
    end

    it 'changes with the schema ids' do
      base = described_class.input_digest(ctx)
      ctx.schema = [ answer_field(id: 'ashby:_systemfield_email') ]

      expect(described_class.input_digest(ctx)).not_to eq(base)
    end

    it 'is nil on replay (always re-runs)' do
      expect(described_class.input_digest(ctx, replay: true)).to be_nil
    end
  end
end
