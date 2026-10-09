# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::VerifySubmit do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:graphql) { 'https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiSubmitSingleApplicationFormAction' }
  # The real ApiSubmitSingleApplicationFormAction answer (the SPA aliases the mutation as submitApplicationFormAction).
  let(:accepted_body) do
    { data: { submitApplicationFormAction: { applicationFormResult: { __typename: 'FormSubmitSuccess', _: nil },
                                             messages: { blockMessageForCandidateHtml: nil } } } }.to_json
  end
  let(:success_container) { Apply::Platform::Ashby::SUCCESS_SELECTORS.first }
  let(:gemini) { %r{generativelanguage\.googleapis\.com.*generateContent} }
  let(:evidence) { submit_evidence }
  let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.ashbyhq.com/preply/x/application') }

  subject(:verdict) { described_class.call(ctx:).model }

  # Ashby: confirmation texts, the confirmation view (success_dom), the submit mutation (body_ok: FormSubmitSuccess),
  # failure views as a veto, min_signals 2.
  before do
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.new(
      key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => '20587adf-cf02-473e-8a80-7b009711a2cf' },
      frame_path: nil, from_alias: false, probable: nil
    ))
    ctx.open_scope!(:submit, session, 5.minutes.from_now)
    result = ApplyMate::Operation::Result.new
    result[:model] = evidence
    allow(Apply::Operation::Engine::CollectSubmitEvidence).to receive(:call).and_return(result)
  end

  def submit_evidence(text: 'Customer Care Team Lead', urls: [ 'https://jobs.ashbyhq.com/preply/x/application' ], requests: [],
                      in_flight: 0, success_dom: [], failure_dom: [], form_present: false, field_errors: {})
    Apply::Operation::Engine::CollectSubmitEvidence::Evidence.new(text:, urls:, requests:, in_flight:, success_dom:, failure_dom:,
                                                                  form_present:, field_errors:)
  end

  def request(url, status, body = nil, body_error: nil)
    { url:, method: 'POST', status:, at: 1, frame_url: url, body:, body_error: }
  end

  def ai_says(submitted:, confidence: 0.95, quote: 'Thank you for applying')
    stub_request(:post, gemini).to_return(gemini_json_response({ submitted:, confidence:, quote: }.to_json))
  end

  context 'with the success text and an accepted submit mutation' do
    let(:evidence) { submit_evidence(text: 'Thank you for applying!', requests: [ request(graphql, 200, accepted_body) ]) }

    it 'is submitted on two deterministic signals, without asking the AI' do
      expect(verdict.status).to eq(:submitted)
      expect(verdict.evidence).to include('count' => 2, 'min_signals' => 2,
                                          'signals' => { 'success_text' => true, 'success_dom' => false, 'url_match' => false,
                                                         'submit_request' => true, 'ai' => false },
                                          'submit_op' => [ { 'status' => 200, 'body' => 'ok' } ])
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  # Apply 227 (Preply): the org replaced Ashby's default sentence, so no text pattern matched and the verify stopped
  # at "signals 1/2". The confirmation view is the copy-independent signal.
  context "with the org's own confirmation copy in Ashby's confirmation view and an accepted submit mutation" do
    let(:evidence) do
      submit_evidence(text: 'Success We will carefully review your profile and contact you once there is news to share.',
                      success_dom: [ success_container ], requests: [ request(graphql, 200, accepted_body) ])
    end

    it 'is submitted on the confirmation view and the mutation, without asking the AI' do
      expect(verdict.status).to eq(:submitted)
      expect(verdict.evidence['signals']).to include('success_text' => false, 'success_dom' => true, 'submit_request' => true)
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  context 'with the confirmation view while the submit body could not be read' do
    let(:evidence) do
      submit_evidence(text: 'Success Application received! Thank you for taking the first step.', success_dom: [ success_container ],
                      requests: [ request(graphql, 200, nil, body_error: 'dropped') ])
    end

    it 'is submitted on the view and the copy, and records why the body is missing' do
      expect(verdict.status).to eq(:submitted)
      expect(verdict.evidence['submit_op']).to eq([ { 'status' => 200, 'body' => 'dropped' } ])
      expect(verdict.evidence['signals']).to include('success_text' => true, 'success_dom' => true, 'submit_request' => false)
    end
  end

  context 'when Ashby re-renders the form (validation: HTTP 200 with FormRender)' do
    let(:evidence) do
      body = { data: { submitApplicationFormAction: { applicationFormResult: { __typename: 'FormRender' } } } }.to_json
      submit_evidence(text: 'Your form needs corrections', form_present: true, requests: [ request(graphql, 200, body) ])
    end

    it 'does not count the mutation and says so in the detail' do
      expect(verdict.status).to eq(:unknown)
      expect(verdict.evidence['signals']['submit_request']).to be(false)
      expect(verdict.detail).to include('submit_op [200 not_ok]')
    end
  end

  context 'when only another GraphQL op (ApiSetFormValue) answered after the claim' do
    let(:evidence) do
      submit_evidence(text: 'Thank you for applying', requests: [ request(graphql.sub('ApiSubmitSingleApplicationFormAction', 'ApiSetFormValue'), 200, accepted_body) ])
    end

    it 'never counts it as the submit' do
      ai_says(submitted: false, confidence: 0.9, quote: '')

      expect(verdict.evidence).to include('submit_op' => [])
      expect(verdict.evidence['signals']['submit_request']).to be(false)
      expect(verdict.status).to eq(:unknown)
    end
  end

  context 'when a failure view is on the page' do
    let(:evidence) do
      submit_evidence(text: "Application submitted We couldn't submit your application",
                      failure_dom: [ '.ashby-application-form-failure-container' ], requests: [ request(graphql, 200, accepted_body) ])
    end

    it 'is never submitted (the view vetoes) and the AI is not asked' do
      expect(verdict.status).to eq(:unknown)
      expect(verdict.evidence).to include('count' => 2, 'failure_dom' => [ '.ashby-application-form-failure-container' ])
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  describe 'diagnostics of a verdict that is not submitted' do
    let(:evidence) do
      submit_evidence(text: 'Success', success_dom: [ success_container ],
                      requests: [ request(graphql, 200, nil, body_error: 'timeout'), request('https://jobs.ashbyhq.com/api/x', 500) ])
    end

    before { ai_says(submitted: false, confidence: 0.9, quote: '') }

    it 'summarizes every signal, the request counts and the submit op on one line, and logs it' do
      allow(Rails.logger).to receive(:warn)

      expect(verdict.status).to eq(:unknown)
      expect(verdict.detail).to eq(
        'signals 1/2 (success_text=no success_dom=yes url_match=no submit_request=no ai=no); baseline []; ' \
        'requests 2, 2xx 1, in_flight 0; submit_op [200 timeout]; form_present no, field_errors 0; ' \
        "success_dom [#{success_container}], failure_dom []"
      )
      expect(Rails.logger).to have_received(:warn).with(include("apply=#{apply.hashid} verify unknown: #{verdict.detail}"))
    end
  end

  describe 'the baseline taken before the click' do
    # Generic: success texts and thank-you URL fragments, two of them. The careers page itself says "Thank you for
    # your interest" and lives under /success-stories/: neither proves the submit.
    let(:evidence) do
      submit_evidence(text: 'Thank you for your interest in Acme', urls: [ 'https://acme.example/success-stories/jobs/1' ])
    end

    before { ctx.scratch.platform = Apply::Platform::Generic.new(ctx:, match: ctx.match) }

    it 'counts the page signals when they were not there before the click' do
      ctx.scratch.submit_baseline = []

      expect(verdict.status).to eq(:submitted)
      expect(verdict.evidence).to include('count' => 2, 'baseline' => [])
    end

    it 'never counts a success text or a URL match that already held before the click (and never asks the AI)' do
      ctx.scratch.submit_baseline = %w[success_text url_match]

      expect(verdict.status).to eq(:unknown)
      expect(verdict.evidence).to include('count' => 0, 'baseline' => %w[success_text url_match])
      expect(verdict.evidence['signals']).to include('success_text' => false, 'url_match' => false)
      expect(verdict.detail).to include('baseline [success_text, url_match]')
      expect(a_request(:post, gemini)).not_to have_been_made
    end

    it 'still counts a signal that was not in the baseline' do
      ctx.scratch.submit_baseline = [ 'success_text' ]
      ai_says(submitted: true, quote: 'Thank you for your interest')

      expect(verdict.evidence['signals']).to include('success_text' => false, 'url_match' => true)
      expect(verdict.status).to eq(:submitted)
    end
  end

  context 'with enough signals while the form is still there with invalid fields' do
    let(:evidence) do
      submit_evidence(text: 'Thank you for applying', success_dom: [ success_container ], form_present: true,
                      field_errors: { 'ashby:_systemfield_email' => 'Email is required' }, requests: [ request(graphql, 200, accepted_body) ])
    end

    it 'is never submitted (and, with a 2xx since the claim, not rejected either)' do
      expect(verdict.status).to eq(:unknown)
      expect(verdict.evidence).to include('count' => 3, 'field_errors' => [ 'ashby:_systemfield_email' ])
    end
  end

  context 'when a failure view shows and nothing since the claim was accepted' do
    let(:evidence) do
      submit_evidence(text: "We couldn't submit your application", failure_dom: [ '.ashby-application-form-failure-container' ],
                      requests: [ request(graphql, 422, '{}') ])
    end

    it 'is rejected (the failure view is rejection evidence under the in-flight / 4xx rules)' do
      expect(verdict.status).to eq(:rejected)
    end
  end

  context 'when only the success text holds' do
    let(:evidence) { submit_evidence(text: 'Thank you for applying! We will be in touch.') }

    it 'is submitted when the AI corroborates with a quote from the page' do
      ai_says(submitted: true)

      expect(verdict.status).to eq(:submitted)
      expect(verdict.evidence['signals']).to include('success_text' => true, 'ai' => true)
    end

    context 'when the page text carries personal data' do
      let(:page_email) { unique_email('jane.doe') }
      let(:evidence) { submit_evidence(text: "Thank you for applying, we wrote to #{page_email}.") }

      it 'sends the AI only the redacted text inside untrusted markers' do
        prompts = []
        stub_request(:post, gemini)
          .with { |req| prompts << JSON.parse(req.body).dig('contents', 0, 'parts', 0, 'text') }
          .to_return(gemini_json_response({ submitted: true, confidence: 0.9, quote: 'Thank you for applying' }.to_json))

        expect(verdict.status).to eq(:submitted)
        expect(prompts.sole).to include("#{ApplyMate::Ai::Prompt::Base::OPEN_MARK}\nThank you for applying, we wrote to {{email}}.")
        expect(prompts.sole).not_to include(page_email)
      end
    end

    it 'stays unknown when the AI quote is not on the page' do
      ai_says(submitted: true, quote: 'Your application is complete')

      expect(verdict.status).to eq(:unknown)
    end

    it 'stays unknown when the AI is not confident' do
      ai_says(submitted: true, confidence: 0.5)

      expect(verdict.status).to eq(:unknown)
    end

    it 'stays unknown (traced) when the AI call fails' do
      stub_request(:post, gemini).to_return(status: 500, body: '{}')

      expect(verdict.status).to eq(:unknown)
      expect(ctx.scratch.trace.last).to include('event' => 'verify_ai_failed')
    end

    it 'lets a Halt of the AI budget through (the verify does not swallow it)' do
      Apply.where(id: apply.id).update_all(ai_calls_total: Apply::Operation::Engine::CallAi::MAX_AI_CALLS_PER_APPLY)

      expect { verdict }.to raise_error(Apply::Operation::Engine::Halt) { |halt| expect(halt.code).to eq(:ai_lifetime_cap) }
    end

    it 'counts the AI call on the apply' do
      ai_says(submitted: true)
      verdict

      expect(apply.reload.ai_calls).to eq(1)
    end

    it 'asks a browser-backed integration too, in text mode inside the lease' do
      apply.ai_integration.update!(provider: 'gemini_scraping')
      client = instance_double(ApplyMate::Ai::Client::GeminiScraping)
      allow(ApplyMate::Ai::Client::GeminiScraping).to receive(:new).and_return(client)
      answer = { submitted: true, confidence: 0.95, quote: 'Thank you for applying' }.to_json
      allow(client).to receive(:complete)
        .and_return(ApplyMate::Ai::Response.new(text: "Verdict:\n```json\n#{answer}\n```", usage: ApplyMate::Ai::Usage::UNKNOWN))

      expect(verdict.status).to eq(:submitted)
      expect(client).to have_received(:complete).once
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  context 'with no deterministic signal' do
    let(:evidence) { submit_evidence(text: 'Customer Care Team Lead · Overview') }

    it 'is unknown and never asks the AI (an AI verdict alone never counts)' do
      ai_says(submitted: true, quote: 'Customer Care Team Lead')

      expect(verdict.status).to eq(:unknown)
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  context 'when the GraphQL submit answers 200 with errors' do
    let(:evidence) do
      submit_evidence(requests: [ request(graphql, 200, '{"data":null,"errors":[{"message":"Missing required field"}]}') ])
    end

    it 'is not submitted' do
      expect(verdict.status).to eq(:unknown)
      expect(verdict.evidence['signals']['submit_request']).to be(false)
    end
  end

  context 'when the submit body is not JSON' do
    let(:evidence) { submit_evidence(text: 'Thank you for applying', requests: [ request(graphql, 200, '<html>ok</html>') ]) }

    it 'does not count the request' do
      ai_says(submitted: false, confidence: 0.9, quote: '')

      expect(verdict.evidence['signals']['submit_request']).to be(false)
      expect(verdict.status).to eq(:unknown)
    end
  end

  context 'when an XHR answered 201 but a field still shows aria-invalid' do
    let(:evidence) do
      submit_evidence(text: 'Submit Application', form_present: true, field_errors: { 'ashby:_systemfield_email' => 'invalid' },
                      requests: [ request('https://jobs.ashbyhq.com/api/file-upload', 201) ])
    end

    it 'is unknown, not rejected (something was accepted)' do
      expect(verdict.status).to eq(:unknown)
      expect(verdict.evidence).to include('mutations_2xx' => 1, 'field_errors' => [ 'ashby:_systemfield_email' ])
    end
  end

  context 'when the form is still there with field errors and every request after the claim got a 4xx' do
    let(:requests) { [ request(graphql, 422, '{}'), request('https://jobs.ashbyhq.com/api/x', 400) ] }
    let(:in_flight) { 0 }
    let(:evidence) do
      submit_evidence(text: 'Email is required', form_present: true, field_errors: { 'ashby:_systemfield_email' => 'Email is required' },
                      requests:, in_flight:)
    end

    it 'is rejected' do
      expect(verdict.status).to eq(:rejected)
    end

    context 'with no request at all after the claim' do
      let(:requests) { [] }

      it 'is rejected' do
        expect(verdict.status).to eq(:rejected)
      end
    end

    context 'when a request after the claim is still in flight (a slow submit may land after the wait)' do
      let(:in_flight) { 1 }

      it 'is unknown, so the claim is kept' do
        expect(verdict.status).to eq(:unknown)
        expect(verdict.evidence).to include('in_flight' => 1)
      end
    end

    { 'failed at the transport level' => nil, 'answered 5xx' => 502, 'answered a redirect' => 303 }.each do |what, status|
      context "when a request after the claim #{what}" do
        let(:requests) { [ request(graphql, 422, '{}'), request(graphql, status) ] }

        it 'is unknown (the server may have accepted it)' do
          expect(verdict.status).to eq(:unknown)
        end
      end
    end
  end

  context 'when the form is still there without field errors' do
    let(:evidence) { submit_evidence(text: 'Submit Application', form_present: true) }

    it 'is unknown' do
      expect(verdict.status).to eq(:unknown)
    end
  end

  context 'with a platform that needs one signal' do
    let(:evidence) { submit_evidence(urls: [ 'https://acme.example/careers/thanks' ]) }

    it 'is submitted on a URL pattern alone' do
      platform = Class.new(Apply::Platform::Base) do
        def success_evidence
          { texts: [], url_patterns: [ %r{/thanks\z} ], submit_request: nil, min_signals: 1 }
        end
      end
      ctx.scratch.platform = platform.new(ctx:, match: ctx.match)

      expect(verdict.status).to eq(:submitted)
      expect(a_request(:post, gemini)).not_to have_been_made
    end
  end

  describe 'waiting for the signals' do
    let(:evidence) { submit_evidence(text: 'Thank you for applying!', requests: [ request(graphql, 200, accepted_body) ]) }

    it 'polls without the field probes, bounded by EVIDENCE_WAIT, then collects the full evidence once' do
      expect(verdict.status).to eq(:submitted)
      expect(session.calls_of(:wait_until)).to eq([ [ { timeout: described_class::EVIDENCE_WAIT } ] ])
      selectors = { success_selectors: Apply::Platform::Ashby::SUCCESS_SELECTORS, failure_selectors: Apply::Platform::Ashby::FAILURE_SELECTORS }
      expect(Apply::Operation::Engine::CollectSubmitEvidence).to have_received(:call).with(ctx:, field_errors: false, **selectors).ordered
      expect(Apply::Operation::Engine::CollectSubmitEvidence).to have_received(:call).with(ctx:, field_errors: true, **selectors).ordered
    end

    it 'never waits past the run deadline' do
      ctx.close_scope!
      ctx.open_scope!(:submit, session, 7.seconds.from_now)
      verdict

      expect(session.calls_of(:wait_until).sole.sole[:timeout]).to be <= 7
    end

    it 'still decides when the wait runs out' do
      allow(session).to receive(:wait_until).and_return(false)

      expect(verdict.status).to eq(:submitted)
    end
  end
end
