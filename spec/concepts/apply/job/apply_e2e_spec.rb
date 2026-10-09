# frozen_string_literal: true

require 'rails_helper'

# Job -> Handler -> Runner -> real steps, with only the network (HTTP/Gemini/browser) stubbed.
RSpec.describe Apply::Job::Apply, type: :job do
  include ActiveJob::TestHelper

  context 'DOU external apply (HoneyTech: PeopleForce, a platform no adapter knows)' do
    include_context 'honeytech dou'

    before do
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
        .with(HoneytechDou::VACANCY_URL, any_args)
        .and_return(ApplyMate::Client::Response.new(dou_vacancy_html, {}, 200, HoneytechDou::VACANCY_URL))
      stub_honeytech_redirect_walk
      stub_gemini_router
    end

    it 'completes through the Runner on the engine (Navigator, claim, verify), and a re-run is a no-op' do
      perform_enqueued_jobs { described_class.perform_now(apply.id) }

      reloaded = apply.reload
      expect(reloaded).to have_attributes(state: 'completed', submitted_via: 'engine', platform: 'generic')
      expect(reloaded.submit_claimed_at).to be_present
      expect(reloaded.apply_steps.chronological.map(&:key)).to eq(
        %w[check_applyable fetch_apply_type detect schema navigate:survey discover:survey answer generate_cv review
           throttle navigate:replay:submit discover:submit fill:submit submit:submit verify:submit]
      )
      expect(gemini_prompt_kinds).to eq(%i[answers cv verify]) # the landing form is claimed without a Navigate call

      expect { perform_enqueued_jobs { described_class.perform_now(apply.id) } }
        .not_to(change { [ ApplyStep.where(apply_id: apply.id).count, apply.reload.attributes, gemini_prompts.size ] })
      submit_clicks = session.calls_of(:click).map(&:first).select do |target|
        target.strategies.any? { |strategy| strategy['css'] == HoneytechDou::PEOPLEFORCE_SUBMIT }
      end
      expect(submit_clicks.size).to eq(1)
    end

    it 'writes nothing from a zombie run whose run_token was rotated' do
      ctx = Apply::Operation::Engine::StartContext.call(apply:).model
      rotate_run_token!(apply)
      before_attrs = Apply.find(apply.id).attributes

      handler = Apply::Handler::Base.for(apply)
      expect { Apply::Operation::Engine::Run.call(apply:, handler:, ctx:) }.not_to raise_error

      expect(ApplyStep.where(apply_id: apply.id).count).to eq(0)
      expect(Apply.find(apply.id).attributes.except('updated_at')).to eq(before_attrs.except('updated_at'))
    end

    it 'stores the enqueued job id on the apply' do
      job = Apply::Operation::Engine::Enqueue.call(apply:).model

      expect(job).to have_attributes(arguments: [ apply.id ], queue_name: 'apply')
      expect(apply.reload.job_id).to eq(job.job_id)
      expect(enqueued_jobs.map { |entry| entry['job_id'] }).to include(apply.job_id)
    end
  end
end
