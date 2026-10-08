# frozen_string_literal: true

require 'rails_helper'

# Job -> Handler -> Runner -> real steps, with only the network (HTTP/Gemini/browser) stubbed.
RSpec.describe Apply::Job::Apply, type: :job do
  include ActiveJob::TestHelper

  context 'DOU external apply (HoneyTech)' do
    include_context 'honeytech dou'

    before do
      allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
        .with(HoneytechDou::VACANCY_URL, any_args)
        .and_return(ApplyMate::Client::Response.new(dou_vacancy_html, {}, 200, HoneytechDou::VACANCY_URL))
      stub_honeytech_redirect_walk
      stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
        .to_return(
          gemini_check_form_page,
          gemini_fill_form,
          gemini_json_response("```html\n<!DOCTYPE html>\n<html><body><h1>Jane Doe</h1></body></html>\n```"),
          gemini_check_submit_result
        )
    end

    it 'completes through the Runner with a claim and step rows, and a re-run is a no-op' do
      perform_enqueued_jobs { described_class.perform_now(apply.id) }

      reloaded = apply.reload
      expect(reloaded).to have_attributes(state: 'completed', submitted_via: 'engine')
      expect(reloaded.submit_claimed_at).to be_present
      # PeopleForce is unknown in phase 3a: DetectPlatform persists generic, then the legacy external path runs.
      expect(reloaded.platform).to eq('generic')
      expect(reloaded.apply_steps.chronological.map(&:key))
        .to eq(%w[check_applyable fetch_apply_type detect fetch_form fill_form generate_cv submit])

      expect { perform_enqueued_jobs { described_class.perform_now(apply.id) } }
        .not_to(change { [ ApplyStep.where(apply_id: apply.id).count, apply.reload.attributes ] })
      expect(session.calls.count { |call| call.first == :click }).to eq(1)
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
