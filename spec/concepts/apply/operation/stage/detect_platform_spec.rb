# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::DetectPlatform do
  subject(:run) { described_class.call(ctx:) }

  let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
  let(:dou_goto) { 'https://dou.ua/goto/vacancy/?id=375494' }
  let(:preply) { "https://preply.com/en/careers/apply?ashby_jid=#{jid}" }
  let(:ashby_job) { "https://jobs.ashbyhq.com/preply/#{jid}" }
  let(:entry_url) { dou_goto }
  # The careers page as a plain GET sees it: the SPA renders the Ashby embed later (or Cloudflare answers first).
  let(:preply_head) { '<script src="/_next/static/app.js"></script>' }
  let(:apply) { create(:apply).tap { |row| row.vacancy.update!(external_url: entry_url) } }
  let(:ctx) { engine_context(apply) }
  let(:responses) do
    {
      dou_goto => redirect(preply),
      preply => html(preply_head, preply),
      ashby_job => html('<div id="root"></div>', ashby_job)
    }
  end

  def redirect(location)
    ApplyMate::Client::Response.new('', { 'location' => location }, 302, nil)
  end

  def html(body, url)
    ApplyMate::Client::Response.new("<html><head>#{body}</head></html>", {}, 200, url)
  end

  before do
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    allow(ctx.http).to receive(:get) { |url, **| responses.fetch(url) }
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to eq('Визначення платформи')
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to eq('Detecting platform')
  end

  # Owner decision 2026-10-09: every integration drives every platform; an unknown one goes to Generic + Navigator.
  context 'with a GeminiScraping integration (browser-backed, no native JSON schema)' do
    let(:careers) { 'https://careers.example.test/jobs/42' }
    let(:entry_url) { careers }
    let(:responses) { { careers => html('<title>Jobs</title>', careers) } }

    before do
      apply.ai_integration.update!(provider: 'gemini_scraping')
      allow(ApplyMate::Client::Browser::Session).to receive(:open)
    end

    it 'is not halted on a plain generic match: the run goes on to the Generic Navigator' do
      expect { run }.not_to raise_error
      expect(ctx.platform).to be_a(Apply::Platform::Generic)
      expect(apply.reload).to have_attributes(platform: 'generic', landing_url: careers)
    end
  end

  context 'with the Preply chain at the HTTP level (dou.ua -> preply.com?ashby_jid)' do
    it 'stays generic with Ashby as the probable platform and persists the detection' do
      run

      expect(ctx.match).to be_generic
      expect(ctx.match.probable).to have_attributes(key: 'ashby', captures: { 'jid' => jid })
      expect(ctx.platform).to be_a(Apply::Platform::Generic)
      expect(apply.reload).to have_attributes(platform: 'generic', entry_url: dou_goto, apply_key: nil)
      expect(apply.platform_match).to include('key' => 'generic', 'probable' => include('key' => 'ashby'))
    end

    it 'stores the match and the evidence as the step result' do
      step = run[:step_result]

      expect(step['match']).to include('key' => 'generic')
      expect(step['evidence']).to include('hops' => [ dou_goto, preply ], 'current_urls' => [ preply ])
    end

    it 'persists the final URL of the walk as applies.landing_url' do
      run

      expect(apply.reload.landing_url).to eq(preply)
      expect(ctx.landing_url).to eq(preply)
    end
  end

  context 'when the careers page times out at the HTTP level' do
    before do
      allow(ctx.http).to receive(:get).with(preply, any_args)
                                      .and_raise(ApplyMate::Client::ImpersonateHttp::RequestError, 'exit 28')
    end

    it 'detects from the URLs it reached and traces the error (the rendered level redetects)' do
      run

      expect(ctx.match.probable).to have_attributes(key: 'ashby', captures: { 'jid' => jid })
      expect(apply.reload.platform).to eq('generic')
      expect(ctx.scratch.trace.find { |entry| entry['event'] == 'http_evidence' })
        .to include('hops' => [ dou_goto, preply ], 'fetch_error' => 'RequestError: exit 28')
    end
  end

  context 'when the careers page HTML already carries the Ashby embed script' do
    let(:preply_head) { '<script src="https://jobs.ashbyhq.com/preply/embed?version=2"></script>' }

    it 'detects Ashby at the HTTP level (slug from the script, jid from the query)' do
      run

      expect(ctx.match).to have_attributes(key: 'ashby', captures: { 'slug' => 'preply', 'jid' => jid })
      expect(apply.reload.apply_key).to eq("ashby:preply:#{jid}")
    end
  end

  context 'with a direct Ashby job URL' do
    let(:entry_url) { ashby_job }

    it 'adopts Ashby and keys the apply by the posting' do
      run

      expect(ctx.platform).to be_a(Apply::Platform::Ashby)
      expect(apply.reload).to have_attributes(platform: 'ashby', apply_key: "ashby:preply:#{jid}")
      expect(apply.platform_match).to include('key' => 'ashby', 'captures' => { 'slug' => 'preply', 'jid' => jid })
    end

    context 'when the user already applied to the same posting' do
      let!(:previous) do
        create(:apply, user: apply.user, state: :completed, apply_key: "ashby:preply:#{jid}")
      end

      it 'stops for review naming the earlier apply' do
        expect { run }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :already_applied, detail: previous.hashid)
        }
      end

      it 'goes on once the user confirmed the duplicate' do
        apply.update!(duplicate_confirmed_at: Time.current)

        expect { run }.not_to raise_error
        expect(apply.reload.apply_key).to eq("ashby:preply:#{jid}")
      end
    end
  end

  context 'with a Google Form behind the link' do
    let(:entry_url) { 'https://forms.gle/AbC123' }
    let(:responses) { { entry_url => redirect('https://docs.google.com/forms/d/e/x/viewform') } }

    before { responses['https://docs.google.com/forms/d/e/x/viewform'] = html('', nil) }

    it "halts with the 'apply yourself' code before detecting anything" do
      expect { run }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :manual_apply_required, detail: :google_forms)
      }
      expect(apply.reload.platform).to be_nil
    end
  end

  context 'without any entry URL' do
    let(:entry_url) { nil }

    it 'halts with no_application_path' do
      expect { run }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:no_application_path) }
    end
  end

  describe '.input_digest' do
    it 'changes with the entry URL and with the registry fingerprint' do
      digest = described_class.input_digest(ctx)
      apply.entry_url = ashby_job

      expect(described_class.input_digest(ctx)).not_to eq(digest)

      changed = described_class.input_digest(ctx)
      allow(Apply::Platform::Registry).to receive(:fingerprint).and_return('other')

      expect(described_class.input_digest(ctx)).not_to eq(changed)
    end

    it 'does not depend on the AI integration' do
      digest = described_class.input_digest(ctx)
      apply.ai_integration.update!(provider: 'gemini_scraping')

      expect(described_class.input_digest(ctx)).to eq(digest)
    end
  end

  describe '.restore' do
    let(:entry_url) { ashby_job }

    it 'rebuilds the match, the adapter and the evidence on a later attempt' do
      step = run[:step_result]
      fresh = engine_context(apply.reload.tap { |row| row.update_columns(state: Apply.states[:queued]) })

      described_class.restore(fresh, step)

      expect(fresh.match).to have_attributes(key: 'ashby', captures: { 'slug' => 'preply', 'jid' => jid })
      expect(fresh.platform).to be_a(Apply::Platform::Ashby)
      expect(fresh.evidence.current_urls).to eq([ ashby_job ])
    end

    it 'takes the match from applies.platform_match when Redact mangled the stored captures' do
      step = Apply::Operation::Engine::RedactTree.call(value: run[:step_result], apply:).model
      step['match']['captures']['jid'] = '20587adf-{{phone}}'
      fresh = engine_context(apply.reload.tap { |row| row.update_columns(state: Apply.states[:queued]) })

      described_class.restore(fresh, step)

      expect(fresh.match.captures).to eq({ 'slug' => 'preply', 'jid' => jid })
    end

    context 'when the landing URL carries a jid Redact reads as a phone number' do
      let(:jid) { '20587adf-0d9b-4a2e-8c1d-1234567890ab' }
      let(:entry_url) { dou_goto }

      it 'rebuilds the URL evidence from applies.landing_url, never from the redacted step result' do
        step = Apply::Operation::Engine::RedactTree.call(value: run[:step_result], apply:).model
        expect(step.dig('evidence', 'current_urls').sole).not_to eq(preply) # what Redact did to it
        fresh = engine_context(apply.reload.tap { |row| row.update_columns(state: Apply.states[:queued]) })

        described_class.restore(fresh, step)

        expect(fresh.landing_url).to eq(preply)
        expect(fresh.evidence).to have_attributes(current_urls: [ preply ], script_srcs: [], iframe_srcs: [])
        expect(fresh.evidence.hops.first).to eq(dou_goto)
        expect(Apply::Operation::Engine::Detect.call(evidence: fresh.evidence).model.probable.captures).to eq('jid' => jid)
      end
    end

    it 'falls back to the stored result when the persisted match names another platform' do
      step = run[:step_result]
      apply.reload.update_columns(state: Apply.states[:queued], platform_match: step['match'].merge('key' => 'generic'))

      fresh = engine_context(apply)
      described_class.restore(fresh, step)

      expect(fresh.match).to have_attributes(key: 'ashby', captures: { 'slug' => 'preply', 'jid' => jid })
    end
  end
end
