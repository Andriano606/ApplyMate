# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Run, type: :job do
  let(:apply) { create(:apply) }
  let(:handler) { ApplyEngineFakes::Handler.new(apply:) }

  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  def run
    described_class.call(apply:, handler:)
    apply.reload
  end

  def halt(code, **)
    Apply::Operation::Engine::Halt.new(code, **)
  end

  def steps
    apply.apply_steps.chronological
  end

  context 'when every step succeeds' do
    let(:seen) { {} }

    before do
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe) { |ctx| seen[:prepare] = Apply.find(ctx.apply.id).stage }
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe) do |ctx, **options|
        seen[:submit] = Apply.find(ctx.apply.id).stage
        seen[:options] = options
      end
    end

    it 'records one succeeded ApplyStep per step for attempt 1' do
      run

      expect(steps.map { |s| [ s.attempt, s.key, s.stage, s.position, s.state ] }).to eq(
        [ [ 1, 'fake_prepare', 'fake_prepare', 0, 'succeeded' ], [ 1, 'fake_submit', 'fake_submit', 1, 'succeeded' ] ]
      )
      expect(steps.map(&:finished_at)).to all(be_present)
    end

    it 'sets applies.stage during each step and forwards add_step options' do
      run

      expect(seen).to eq(prepare: 'fake_prepare', submit: 'fake_submit', options: { label: 'fake' })
    end

    it 'ends completed, submitted by the engine, with no stage' do
      run

      expect(apply).to be_completed
      expect(apply.submitted_at).to be_present
      expect(apply.submitted_via).to eq('engine')
      expect(apply.stage).to be_nil
      expect(apply.attempt).to eq(1)
    end

    it 'broadcasts each stage and the final state' do
      run

      expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).exactly(3).times
    end

    it 'shuts the heartbeat ticker down' do
      ticker = Concurrent::TimerTask.new(execution_interval: 30) { nil }
      allow(Apply::Operation::Engine::Heartbeat).to receive(:call)
        .and_return(instance_double(ApplyMate::Operation::Result, model: ticker))
      allow(ticker).to receive(:shutdown)

      run

      expect(ticker).to have_received(:shutdown)
    end
  end

  it 'skips a step whose if: condition is falsy for the context' do
    stub_const('ConditionalHandler', Class.new(Apply::Handler::Base))
    ConditionalHandler.add_step(ApplyEngineFakes::PrepareStep, if: ->(ctx) { ctx.apply.external? })
    ConditionalHandler.add_step(ApplyEngineFakes::SubmitStep, if: ->(ctx) { ctx.attempt == 1 })

    described_class.call(apply:, handler: ConditionalHandler.new(apply:))

    expect(steps.map(&:key)).to eq([ 'fake_submit' ])
    expect(apply.reload).to be_completed
  end

  context 'when a step halts before the claim' do
    before do
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe).and_raise(halt(:no_application_path, detail: 'no reply'))
    end

    it 'records the halt state and a failed ApplyStep with the code' do
      run

      expect(apply).to be_unsupported
      expect(apply.failure).to include('code' => 'no_application_path', 'stage' => 'fake_submit', 'after_claim' => false)
      expect(steps.map(&:state)).to eq(%w[succeeded failed])
      expect(steps.last).to have_attributes(error_code: 'no_application_path', error_detail: 'no reply')
      expect(steps.last.finished_at).to be_present
    end
  end

  context 'when a step raises an unexpected error' do
    before do
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe) { raise ArgumentError, "bad value for #{apply.user.email}" }
      allow(Rails.error).to receive(:report)
    end

    it 'fails with unexpected_error and a redacted detail' do
      run

      expect(apply).to be_failed
      expect(apply.failure).to include('code' => 'unexpected_error', 'kind' => 'permanent',
                                       'detail' => 'ArgumentError: bad value for {{fact.email}}')
      expect(steps.sole).to have_attributes(state: 'failed', error_code: 'unexpected_error',
                                            error_detail: 'ArgumentError: bad value for {{fact.email}}')
      expect(Rails.error).to have_received(:report).with(an_instance_of(ArgumentError), hash_including(:context))
    end
  end

  it 'maps an empty AI response to invalid_ai_output' do
    allow(ApplyEngineFakes::PrepareStep).to receive(:observe).and_raise(ApplyMate::Ai::Client::Base::EmptyResponse, 'empty')

    expect(run.failure).to include('code' => 'invalid_ai_output')
    expect(apply).to be_failed
  end

  it 'maps a failed step result to invalid_record with its messages' do
    allow(ApplyEngineFakes::PrepareStep).to receive(:observe) do |ctx|
      ctx.apply.errors.add(:base, 'Form has no inputs')
      raise ActiveRecord::RecordInvalid, ctx.apply
    end

    expect(run).to be_failed
    expect(apply.failure).to include('code' => 'invalid_record', 'detail' => 'Form has no inputs')
    expect(steps.sole.error_code).to eq('invalid_record')
  end

  describe 'auto-resume of a transient halt' do
    before { allow(ApplyEngineFakes::PrepareStep).to receive(:observe).and_raise(halt(:worker_lost)) }

    it 're-queues once, then stays failed' do
      expect { run }.to have_enqueued_job(Apply::Job::Apply).with(apply.id).exactly(:once)
      expect(apply).to be_queued
      expect(apply.failure).to include('code' => 'worker_lost', 'auto_resumed' => true)

      expect { run }.not_to have_enqueued_job(Apply::Job::Apply)
      expect(apply).to be_failed
      expect(apply.attempt).to eq(2)
      expect(apply.failure).to include('code' => 'worker_lost', 'auto_resumed' => true, 'attempt' => 2)
    end
  end

  describe 'browser errors' do
    def raise_in_prepare(error)
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe).and_raise(error)
      allow(Rails.error).to receive(:report)
    end

    context 'when no browser slot is free (PoolBusy)' do
      before { raise_in_prepare(ApplyMate::Client::Browser::PoolBusy.new('3 busy answers')) }

      it 're-raises for the job retry and parks the row in waiting_capacity' do
        Apply.where(id: apply.id).update_all(failure: { 'code' => 'worker_lost' })

        expect { described_class.call(apply:, handler:) }.to raise_error(ApplyMate::Client::Browser::PoolBusy)
        apply.reload

        expect(apply).to be_waiting_capacity
        expect(apply.stage).to be_nil
        expect(apply.failure).to eq('code' => 'worker_lost')
        expect(steps.sole).to have_attributes(state: 'failed', error_code: 'capacity')
        expect(steps.sole.finished_at).to be_present
        expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).at_least(:twice)
      end

      it 'shuts the heartbeat ticker down' do
        ticker = Concurrent::TimerTask.new(execution_interval: 30) { nil }
        allow(Apply::Operation::Engine::Heartbeat).to receive(:call)
          .and_return(instance_double(ApplyMate::Operation::Result, model: ticker))
        allow(ticker).to receive(:shutdown)

        expect { described_class.call(apply:, handler:) }.to raise_error(ApplyMate::Client::Browser::PoolBusy)

        expect(ticker).to have_received(:shutdown)
      end
    end

    it 'auto-resumes a Crashed browser once as browser_crashed' do
      raise_in_prepare(ApplyMate::Client::Browser::Crashed.new('gone'))

      expect { run }.to have_enqueued_job(Apply::Job::Apply).with(apply.id)
      expect(apply).to be_queued
      expect(apply.failure).to include('code' => 'browser_crashed', 'auto_resumed' => true)
      expect(steps.sole.error_code).to eq('browser_crashed')
    end

    it 'maps DeadlineExceeded to deadline' do
      raise_in_prepare(ApplyMate::Client::Browser::DeadlineExceeded.new('late'))

      expect { run }.to have_enqueued_job(Apply::Job::Apply)
      expect(apply.failure).to include('code' => 'deadline')
    end

    it 'maps a busy local Chrome slot (GeminiScraping, the Grover render) to a transient capacity halt' do
      raise_in_prepare(ApplyMate::Client::LocalChrome::Busy.new('slot taken'))
      run

      expect(apply.failure).to include('code' => 'capacity', 'kind' => 'transient')
    end

    it 'maps an AI provider overload / quota (Unavailable) to a transient capacity halt with the key redacted' do
      raise_in_prepare(ApplyMate::Ai::Client::Base::Unavailable.new('Faraday::TooManyRequestsError: 429 for POST https://g.example/x?key=AIzaSyFAKE'))

      expect { run }.to have_enqueued_job(Apply::Job::Apply)
      expect(apply.failure).to include('code' => 'capacity', 'kind' => 'transient')
      expect(apply.failure.to_json).not_to include('AIzaSyFAKE')
    end

    it 'maps an exhausted AI quota to needs_human ai_quota_exhausted, without auto-resume' do
      raise_in_prepare(ApplyMate::Ai::Client::Base::QuotaExhausted.new('Faraday::TooManyRequestsError: PerDay quota'))

      expect { run }.not_to have_enqueued_job(Apply::Job::Apply)
      expect(apply).to be_needs_human
      expect(apply.failure).to include('code' => 'ai_quota_exhausted', 'kind' => 'needs_human')
    end

    it 'stores no credential of an unexpected error in failure.detail or the step error_detail' do
      google_key = "AIza#{SecureRandom.alphanumeric(35)}"
      raise_in_prepare(RuntimeError.new("boom #{google_key} https://h.example/x?apikey=S3CRET&signature=S1G"))
      run

      expect(apply.failure).to include('code' => 'unexpected_error')
      stored = [ apply.failure.to_json, *ApplyStep.where(apply:).pluck(:error_detail) ].join(' ')
      expect(stored).not_to include(google_key)
      expect(stored).not_to match(/S3CRET|S1G/)
    end

    it 'maps an AI timeout too short for the client to deadline, not capacity' do
      raise_in_prepare(ApplyMate::Ai::Client::Base::DeadlineTooShort.new('20 s left'))

      expect { run }.to have_enqueued_job(Apply::Job::Apply)
      expect(apply.failure).to include('code' => 'deadline', 'kind' => 'transient')
    end

    it 'maps TargetNotFound to a failed target_not_found without auto-resume' do
      raise_in_prepare(ApplyMate::Client::Browser::TargetNotFound.new(nil, 'no element for #send'))

      expect { run }.not_to have_enqueued_job(Apply::Job::Apply)
      expect(apply).to be_failed
      expect(apply.failure).to include('code' => 'target_not_found')
    end

    it 'maps VersionMismatch to a permanent unexpected_error' do
      raise_in_prepare(ApplyMate::Client::Browser::VersionMismatch.new('1.0 vs 1.63'))

      expect(run).to be_failed
      expect(apply.failure).to include('code' => 'unexpected_error', 'kind' => 'permanent')
    end

    it 'maps UnsafeUrlError to private_address and unsupported' do
      raise_in_prepare(ApplyMate::Net::UnsafeUrlError.new(:private, url: 'http://10.0.0.1/', host: '10.0.0.1'))

      expect(run).to be_unsupported
      expect(apply.failure).to include('code' => 'private_address')
    end
  end

  it 'halts with deadline before the next step once the run is out of time' do
    allow(ApplyEngineFakes::PrepareStep).to receive(:observe) { travel(Apply::RUN_DEADLINE + 1.minute) }

    run
    travel_back

    expect(apply.failure).to include('code' => 'deadline', 'stage' => 'fake_prepare')
    expect(steps.map(&:key)).to eq([ 'fake_prepare' ])
  end

  describe 'claim rule' do
    it 'records submit_unverified and keeps the claim when the submit step halts after claiming' do
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe) do |ctx|
        Apply::Operation::Engine::ClaimSubmit.call(ctx:)
        raise halt(:validation_rejected)
      end

      run

      expect(apply).to be_submit_unverified
      expect(apply).to be_claimed
      expect(apply.failure).to include('code' => 'validation_rejected', 'after_claim' => true)
    end

    it 'records failed and releases the claim for a definitive rejection' do
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe) do |ctx|
        Apply::Operation::Engine::ClaimSubmit.call(ctx:)
        raise halt(:validation_rejected, definitive: true)
      end

      run

      expect(apply).to be_failed
      expect(apply.submit_claimed_at).to be_nil
    end

    it 'records submit_unverified when the step claims twice' do
      allow(ApplyEngineFakes::SubmitStep).to receive(:observe) do |ctx|
        2.times { Apply::Operation::Engine::ClaimSubmit.call(ctx:) }
      end

      run

      expect(apply).to be_submit_unverified
      expect(apply.failure).to include('code' => 'already_claimed')
    end
  end

  describe 'fencing' do
    it 'writes nothing further once another run rotated the token (zombie)' do
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe) do |ctx|
        rotate_run_token!(ctx.apply)
        Apply.where(id: ctx.apply.id).update_all(state: Apply.states[:running], stage: 'other_run')
      end

      run

      expect(apply).to be_running
      expect(apply.stage).to eq('other_run')
      expect(apply.failure).to be_nil
      expect(steps.map(&:key)).to eq([ 'fake_prepare' ])
    end

    it 'stops before the next step once the heartbeat fenced the context' do
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe) { |ctx| ctx.fence! }

      run

      expect(apply).to be_running
      expect(apply.stage).to eq('fake_prepare')
      expect(steps.map(&:key)).to eq([ 'fake_prepare' ])
    end
  end

  it 'writes nothing when another live run owns the apply' do
    Apply.where(id: apply.id).update_all(state: Apply.states[:running], heartbeat_at: Time.current,
                                         run_token: SecureRandom.uuid, attempt: 1)

    expect { run }.not_to raise_error
    expect(apply).to be_running
    expect(apply.attempt).to eq(1)
    expect(steps).to be_empty
  end

  describe 'input digests, scopes and session options' do
    let(:handler) { ApplyEngineFakes::ScopedHandler.new(apply:) }
    let(:session) { FakeSession.new(html: '<html></html>', final_url: 'https://example.com/') }

    before { stub_browser_session(session) }

    def keys_of(attempt)
      steps.select { |step| step.attempt == attempt }.map(&:key)
    end

    # Resumes the apply (failed -> queued) so the next Run is a new attempt.
    def requeue!
      Apply.where(id: apply.id).update_all(state: Apply.states[:queued], failure: nil)
      apply.reload
    end

    it 'opens one Session per scope, humanized only for the submit scope, with the apply hashid as identity' do
      run

      expect(session.open_options.size).to eq(2)
      expect(session.open_options.map { |o| o.slice(:humanize, :identity) }).to eq(
        [ { humanize: false, identity: apply.hashid }, { humanize: true, identity: apply.hashid } ]
      )
      expect(session.open_options.first[:owner]).to eq(ApplyMate::Client::Browser::Session.owner_for(apply))
    end

    it 'stores scope, input_digest, a redacted result and a flushed, redacted trace on the step rows' do
      allow(ApplyEngineFakes::DigestOne).to receive(:observe) do |ctx|
        ctx.trace(:probe, note: "mail #{ctx.apply.user.email}")
      end

      run

      row = steps.find { |step| step.key == 'fake_digest_one:survey' }
      expect(row).to have_attributes(scope: 'survey', input_digest: 'v1', result: { 'ran' => 'fake_digest_one' })
      expect(row.trace.sole).to include('event' => 'probe', 'note' => 'mail {{fact.email}}')
      expect(steps.find { |step| step.key == 'fake_digest_two:survey' }.trace).to be_nil
      expect(steps.find { |step| step.key == 'fake_prepare' }).to have_attributes(scope: nil, input_digest: nil)
    end

    it 'completes with the scoped keys in declaration order' do
      run

      expect(keys_of(1)).to eq(%w[fake_prepare fake_digest_one:survey fake_digest_two:survey fake_submit:submit])
      expect(apply).to be_completed
    end

    it 'closes the scope on the context even when a step raises, and fails the row with the mapped code' do
      seen = {}
      allow(ApplyEngineFakes::DigestTwo).to receive(:observe) do |ctx|
        seen[:ctx] = ctx
        raise ApplyMate::Client::Browser::Obstructed.new('locator', 'covered by overlay')
      end
      allow(Rails.error).to receive(:report)

      run

      expect(seen[:ctx]).not_to be_session_open
      expect(steps.last).to have_attributes(key: 'fake_digest_two:survey', state: 'failed', error_code: 'target_obstructed')
      expect(apply).to be_failed
    end

    it 'attaches failure artifacts to the failed row while the scope session is still open' do
      allow(ApplyEngineFakes::DigestTwo).to receive(:observe).and_raise(halt(:target_not_found))

      run

      failed = steps.find(&:failed?)
      expect(failed.artifacts.map { |artifact| artifact.filename.to_s }).to contain_exactly('failure.png', 'failure_f0.html')
      expect(session.calls).to include([ :screenshot, { full_page: false, mask_fillable: true } ])
    end

    it 'closes the scope when the Session cannot be opened' do
      allow(ApplyMate::Client::Browser::Session).to receive(:open).and_raise(ApplyMate::Client::Browser::Crashed, 'gone')
      allow(Rails.error).to receive(:report)

      expect { run }.to have_enqueued_job(Apply::Job::Apply).with(apply.id)
      expect(apply.failure).to include('code' => 'browser_crashed')
      expect(keys_of(1)).to eq(%w[fake_prepare])
    end

    context 'when a second attempt starts after a failure in the submit scope' do
      before do
        allow(ApplyEngineFakes::SubmitStep).to receive(:observe).and_raise(halt(:target_not_found))
        run
        RSpec::Mocks.space.proxy_for(ApplyEngineFakes::SubmitStep).reset
        requeue!
      end

      it 'skips the survey scope entirely (restore, no rows, no Session) and re-runs the rest' do
        restored = []
        allow(ApplyEngineFakes::DigestOne).to receive(:restored) { |_ctx, result| restored << [ :one, result ] }
        allow(ApplyEngineFakes::DigestTwo).to receive(:restored) { |_ctx, result| restored << [ :two, result ] }
        session.open_options.clear

        run

        expect(restored).to eq([ [ :one, { 'ran' => 'fake_digest_one' } ], [ :two, { 'ran' => 'fake_digest_two' } ] ])
        expect(keys_of(2)).to eq(%w[fake_prepare fake_submit:submit])
        expect(session.open_options.size).to eq(1)
        expect(apply).to be_completed
      end

      it 're-runs the whole scope when one digest changed' do
        allow(ApplyEngineFakes::DigestTwo).to receive(:digest).and_return('v2')
        session.open_options.clear

        run

        expect(keys_of(2)).to eq(%w[fake_prepare fake_digest_one:survey fake_digest_two:survey fake_submit:submit])
        expect(session.open_options.size).to eq(2)
      end
    end

    context 'when a scope failed in one of its steps' do
      it 'runs all steps of the scope again in ONE Session on the next attempt' do
        allow(ApplyEngineFakes::DigestTwo).to receive(:observe).and_raise(halt(:target_not_found))
        run
        RSpec::Mocks.space.proxy_for(ApplyEngineFakes::DigestTwo).reset
        requeue!
        session.open_options.clear

        run

        expect(keys_of(2)).to eq(%w[fake_prepare fake_digest_one:survey fake_digest_two:survey fake_submit:submit])
        expect(session.open_options.size).to eq(2) # survey + submit
        expect(apply).to be_completed
      end
    end

    it 'does not skip a scope whose succeeded rows come from different attempts' do
      handler # build
      run
      # Pretend step one of the scope succeeded in attempt 1 and step two in a later attempt: not one unit.
      ApplyStep.where(apply_id: apply.id, key: 'fake_digest_two:survey').update_all(attempt: 2)
      Apply.where(id: apply.id).update_all(state: Apply.states[:queued], attempt: 2)
      apply.reload
      session.open_options.clear

      run

      expect(keys_of(3)).to include('fake_digest_one:survey', 'fake_digest_two:survey')
    end

    it 'leaves no rows and opens no Session for a scope whose condition is falsy' do
      stub_const('FalsyScopeHandler', Class.new(Apply::Handler::Base))
      FalsyScopeHandler.session_scope(:survey, if: ->(_ctx) { false }) { FalsyScopeHandler.add_step(ApplyEngineFakes::DigestOne) }
      FalsyScopeHandler.add_step(ApplyEngineFakes::PrepareStep)

      described_class.call(apply:, handler: FalsyScopeHandler.new(apply:))

      expect(steps.map(&:key)).to eq(%w[fake_prepare])
      expect(session.open_options).to be_empty
    end

    it 'skips a scope-less digest stage whose digest matches an earlier succeeded row' do
      stub_const('DigestHandler', Class.new(Apply::Handler::Base))
      DigestHandler.add_step(ApplyEngineFakes::DigestOne)
      DigestHandler.add_step(ApplyEngineFakes::PrepareStep)
      described_class.call(apply:, handler: DigestHandler.new(apply:))
      requeue!
      allow(ApplyEngineFakes::DigestOne).to receive(:restored)

      described_class.call(apply:, handler: DigestHandler.new(apply:))

      expect(ApplyEngineFakes::DigestOne).to have_received(:restored).with(anything, { 'ran' => 'fake_digest_one' })
      expect(keys_of(2)).to eq(%w[fake_prepare])
    end

    it 're-runs a scope-less digest stage when its digest changed' do
      stub_const('DigestHandler', Class.new(Apply::Handler::Base))
      DigestHandler.add_step(ApplyEngineFakes::DigestOne)
      described_class.call(apply:, handler: DigestHandler.new(apply:))
      requeue!
      allow(ApplyEngineFakes::DigestOne).to receive(:digest).and_return('other')

      described_class.call(apply:, handler: DigestHandler.new(apply:))

      expect(keys_of(2)).to eq(%w[fake_digest_one])
    end
  end

  describe 'Throttled' do
    let(:until_time) { 20.minutes.from_now.change(usec: 0) }

    before do
      allow(ApplyEngineFakes::PrepareStep).to receive(:observe)
        .and_raise(Apply::Operation::Engine::Throttled.new(until: until_time))
    end

    it 're-raises for the job and parks the row in waiting_capacity with a capacity step row' do
      expect { described_class.call(apply:, handler:) }.to raise_error(Apply::Operation::Engine::Throttled) do |error|
        expect(error.until).to eq(until_time)
      end
      apply.reload

      expect(apply).to be_waiting_capacity
      expect(apply.stage).to be_nil
      expect(steps.sole).to have_attributes(state: 'failed', error_code: 'capacity')
    end
  end
end
