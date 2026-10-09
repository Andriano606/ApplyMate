# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Context do
  let(:apply) { build(:apply, stage: 'fake_prepare') }
  let(:ctx) do
    described_class.new(apply:, attempt: 2, run_token: SecureRandom.uuid, deadline_at: 10.minutes.from_now,
                        fence_flag: Concurrent::AtomicBoolean.new(false))
  end

  it 'reports the seconds left until the deadline' do
    freeze_time do
      expect(ctx.remaining).to be_within(0.001).of(600.0)
    end
  end

  it 'is negative once the deadline passed' do
    ctx
    travel_to(11.minutes.from_now) do
      expect(ctx.remaining).to be < 0
    end
  end

  describe '#scope_deadline' do
    it 'is SCOPE_DEADLINE from now while the run has more time' do
      freeze_time do
        expect(ctx.with(deadline_at: 30.minutes.from_now).scope_deadline).to eq(described_class::SCOPE_DEADLINE.from_now)
      end
    end

    it 'never passes the run deadline' do
      freeze_time do
        deadline = 3.minutes.from_now

        expect(ctx.with(deadline_at: deadline).scope_deadline).to eq(deadline)
      end
    end

    it 'is shorter than the browserd lease TTL' do
      expect(described_class::SCOPE_DEADLINE).to be < 600.seconds
    end
  end

  it 'reads the current stage from the apply' do
    expect(ctx.current_stage).to eq('fake_prepare')
  end

  it 'fences through the shared flag' do
    expect { ctx.check_fence! }.not_to raise_error

    ctx.fence!

    expect(ctx).to be_fenced
    expect { ctx.check_fence! }.to raise_error(Apply::Operation::Engine::Fenced)
  end

  it 'starts every run with empty counters (no follow-up answer calls yet)' do
    expect(ctx.scratch).to have_attributes(followup_calls: 0, wizard_page: 1, platform_switches: 0, artifacts_count: 0,
                                           consent_clicks: 0)
  end

  it 'shares the scratch (followup_calls included) between copies' do
    ctx.scratch.followup_calls += 1

    expect(ctx.with(attempt: 3).scratch.followup_calls).to eq(1)
  end

  it 'shares the flag between copies (the heartbeat thread holds the same object)' do
    copy = ctx.with(attempt: 3)
    ctx.fence!

    expect(copy).to be_fenced
  end

  describe 'platform detection' do
    let(:match_class) { Apply::Operation::Engine::Detect::Match }
    let(:other_platform) { Class.new(Apply::Platform::Base) }
    let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
    let(:evidence) { Apply::Operation::Engine::Detect::Evidence.build(current_urls: [ 'https://example.com' ]) }
    let(:detected) { [] }

    def known(key, confidence: 0.95, captures: {})
      match_class.new(key:, confidence:, captures:, frame_path: nil, from_alias: false, probable: nil)
    end

    before do
      allow(Apply::Operation::Engine::Detect).to receive(:call) do
        ApplyMate::Operation::Result.new.tap { |result| result[:model] = detected.shift }
      end
      allow(Apply::Platform::Registry).to receive(:find!).and_call_original
      allow(Apply::Platform::Registry).to receive(:find!).with('other').and_return(other_platform)
    end

    it 'adopts the first detection and instantiates its adapter with the run context' do
      detected << known('ashby', captures: { 'slug' => 'preply', 'jid' => jid })

      ctx.redetect!(evidence)

      expect(ctx.match.key).to eq('ashby')
      expect(ctx.platform).to be_a(Apply::Platform::Ashby).and(have_attributes(ctx:, match: ctx.match))
      expect(ctx).to be_platform_known
    end

    it 'merges evidence across levels before detecting again' do
      rendered = Apply::Operation::Engine::Detect::Evidence.build(iframe_srcs: [ 'https://jobs.ashbyhq.com/x' ])
      detected.push(match_class.generic, match_class.generic)

      ctx.redetect!(evidence)
      ctx.redetect!(rendered)

      expect(ctx.evidence).to have_attributes(current_urls: [ 'https://example.com' ],
                                              iframe_srcs: [ 'https://jobs.ashbyhq.com/x' ])
      expect(Apply::Operation::Engine::Detect).to have_received(:call).with(evidence: ctx.evidence)
    end

    it 'upgrades generic to a platform that crosses the threshold, and traces the switch' do
      detected.push(match_class.generic(probable: known('ashby', confidence: 0.6)), known('ashby'))

      ctx.redetect!(evidence)
      ctx.redetect!(evidence)

      expect(ctx.match.key).to eq('ashby')
      expect(ctx.scratch.trace.last).to include('event' => 'platform_switch', 'from' => 'generic', 'to' => 'ashby')
    end

    it 'never demotes a known platform to generic' do
      detected.push(known('ashby'), match_class.generic)

      ctx.redetect!(evidence)
      ctx.redetect!(evidence)

      expect(ctx.platform).to be_a(Apply::Platform::Ashby)
    end

    it 'stops switching after MAX_PLATFORM_SWITCHES (no flip-flop between two adapters)' do
      detected.push(known('ashby'), known('other'), known('ashby'), known('other'), known('ashby'))

      5.times { ctx.redetect!(evidence) }

      expect(ctx.scratch.platform_switches).to eq(described_class::MAX_PLATFORM_SWITCHES)
      expect(ctx.match.key).to eq('ashby')
      # ashby (adopted), other (switch 1), ashby (switch 2), other (capped), ashby (same platform: re-adopted)
      expect(ctx.scratch.trace.pluck('event')).to eq(%w[platform_switch platform_switch platform_switch_capped])
    end

    it 'falls back to the persisted platform before anything is detected' do
      expect(ctx).not_to be_platform_known

      apply.platform = 'ashby'

      expect(ctx).to be_platform_known
    end
  end

  describe '#trace' do
    it 'keeps the newest MAX_TRACE entries' do
      (described_class::MAX_TRACE + 5).times { |index| ctx.trace(:tick, index:) }

      expect(ctx.scratch.trace.size).to eq(described_class::MAX_TRACE)
      expect(ctx.scratch.trace.first).to include('event' => 'tick', 'index' => 5)
    end
  end

  describe '#flush_trace!' do
    it 'returns the collected entries and starts an empty trace' do
      ctx.trace(:one)

      expect(ctx.flush_trace!.map { |entry| entry['event'] }).to eq([ 'one' ])
      expect(ctx.flush_trace!).to eq([])
    end
  end

  describe 'session scope' do
    it 'opens and closes a scope with its session and deadline' do
      deadline = 5.minutes.from_now
      ctx.open_scope!(:survey, :session, deadline)

      expect(ctx).to be_session_open
      expect(ctx.scratch).to have_attributes(scope: :survey, scope_deadline: deadline)
      expect(ctx.remaining).to be < 5.minutes + 1.second

      ctx.close_scope!

      expect(ctx).not_to be_session_open
      expect(ctx.scratch).to have_attributes(scope: nil, scope_deadline: nil)
    end
  end

  describe '#survey_needed?' do
    let(:platform) { instance_double(Apply::Platform::Base, canonical_form_url: 'https://jobs.example.com/f') }

    before { ctx.scratch.platform = platform }

    it 'is false with a canonical form URL and a schema' do
      ctx.schema = [ instance_double(Apply::Field) ]

      expect(ctx).not_to be_survey_needed
    end

    it 'is true without a schema' do
      expect(ctx).to be_survey_needed
    end

    it 'is true without a canonical form URL' do
      ctx.schema = [ instance_double(Apply::Field) ]
      allow(platform).to receive(:canonical_form_url).and_return(nil)

      expect(ctx).to be_survey_needed
    end

    it 'is true without a platform' do
      ctx.scratch.platform = nil

      expect(ctx).to be_survey_needed
    end
  end

  describe '#schema_keys' do
    it 'strips the platform prefix from the schema field ids' do
      ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.new(
        key: 'ashby', confidence: 0.95, captures: { 'slug' => 's', 'jid' => 'j' }, frame_path: nil, from_alias: false,
        probable: nil
      ))
      ctx.schema = [ instance_double(Apply::Field, id: 'ashby:_systemfield_name') ]

      expect(ctx.schema_keys).to eq([ '_systemfield_name' ])
    end
  end

  describe '#entry_url' do
    it 'prefers the apply entry URL over the vacancy external URL' do
      apply.vacancy.external_url = 'https://dou.ua/goto/vacancy/?id=1'

      expect(ctx.entry_url).to eq('https://dou.ua/goto/vacancy/?id=1')

      apply.entry_url = 'https://jobs.example.com/1'

      expect(ctx.entry_url).to eq('https://jobs.example.com/1')
    end
  end

  describe '#landing_url' do
    it 'is the final URL of the HTTP redirect walk (applies.landing_url), else the entry URL' do
      apply.entry_url = 'https://dou.ua/goto/vacancy/?id=1'

      expect(ctx.landing_url).to eq('https://dou.ua/goto/vacancy/?id=1')

      apply.landing_url = 'https://acme.example/careers'

      expect(ctx.landing_url).to eq('https://acme.example/careers')
    end

    it 'never reads the (possibly redacted) evidence' do
      ctx.evidence = Apply::Operation::Engine::Detect::Evidence.build(current_urls: [ 'https://acme.example/careers?id={{phone}}' ])
      apply.landing_url = 'https://acme.example/careers?id=1234567890'

      expect(ctx.landing_url).to eq('https://acme.example/careers?id=1234567890')
    end
  end

  describe '#clamp' do
    it 'never returns more than the run has left, nor less than zero' do
      expect(ctx.clamp(5)).to eq(5)
      expect(ctx.clamp(3600)).to be_within(1).of(600)

      ctx.scratch.scope_deadline = 1.minute.ago

      expect(ctx.clamp(5)).to eq(0)
    end
  end

  describe '#field_list' do
    it 'prefers the survey fields and falls back to the persisted list' do
      persisted = answer_field(id: 'persisted')
      ctx.apply.fields = [ persisted.to_h ]
      expect(ctx.field_list.map(&:id)).to eq(%w[persisted])

      ctx.fields = [ answer_field(id: 'surveyed') ]
      expect(ctx.field_list.map(&:id)).to eq(%w[surveyed])
    end
  end
end
