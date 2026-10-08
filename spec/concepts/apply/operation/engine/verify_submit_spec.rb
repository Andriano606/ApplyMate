# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::VerifySubmit do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:graphql) { 'https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiSubmitSingleApplicationFormAction' }
  let(:accepted_body) { '{"data":{"submitSingleApplicationFormAction":{"applicationFormResult":{"__typename":"FormSubmitSuccess"}}}}' }
  let(:gemini) { %r{generativelanguage\.googleapis\.com.*generateContent} }
  let(:evidence) { submit_evidence }
  let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.ashbyhq.com/preply/x/application') }

  subject(:verdict) { described_class.call(ctx:).model }

  # Ashby: two texts, the GraphQL submit_request (body_ok: no errors, data present), min_signals 2.
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
                      in_flight: 0, form_present: false, field_errors: {})
    Apply::Operation::Engine::CollectSubmitEvidence::Evidence.new(text:, urls:, requests:, in_flight:, form_present:, field_errors:)
  end

  def request(url, status, body = nil)
    { url:, method: 'POST', status:, at: 1, frame_url: url, body: }
  end

  def ai_says(submitted:, confidence: 0.95, quote: 'Thank you for applying')
    stub_request(:post, gemini).to_return(gemini_json_response({ submitted:, confidence:, quote: }.to_json))
  end

  context 'with the success text and an accepted submit mutation' do
    let(:evidence) { submit_evidence(text: 'Thank you for applying!', requests: [ request(graphql, 200, accepted_body) ]) }

    it 'is submitted on two deterministic signals, without asking the AI' do
      expect(verdict.status).to eq(:submitted)
      expect(verdict.evidence).to include('count' => 2, 'min_signals' => 2,
                                          'signals' => { 'success_text' => true, 'url_match' => false, 'submit_request' => true, 'ai' => false })
      expect(a_request(:post, gemini)).not_to have_been_made
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

    it 'never asks a browser-backed integration (no second browser while the lease is open)' do
      apply.ai_integration.update!(provider: 'gemini_scraping')

      expect(verdict.status).to eq(:unknown)
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
      expect(Apply::Operation::Engine::CollectSubmitEvidence).to have_received(:call).with(ctx:, field_errors: false).ordered
      expect(Apply::Operation::Engine::CollectSubmitEvidence).to have_received(:call).with(ctx:).ordered
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
