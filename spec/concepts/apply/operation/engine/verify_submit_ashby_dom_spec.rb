# frozen_string_literal: true

require 'rails_helper'

# Regression on the real Ashby post-submit DOM (Preply, apply 227): the org's own copy ("Success" / "Application
# received! Thank you for taking the first step...") inside .ashby-application-form-success-container, which replaced
# the form controls inside #form[role=tabpanel]. CollectSubmitEvidence and VerifySubmit run unstubbed on it.
RSpec.describe Apply::Operation::Engine::VerifySubmit do
  let(:ctx) { engine_context(create(:apply)) }
  let(:html) { file_fixture('apply_engine/ashby/post_submit_success.html').read }
  let(:application_url) { 'https://jobs.ashbyhq.com/preply/938ee00b-6bf2-4702-b5d5-aa5e8f110155/application' }
  let(:session) { FakeSession.new(html:, final_url: application_url) }
  let(:submit_url) { 'https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiSubmitSingleApplicationFormAction' }
  let(:submit_body) do
    { data: { submitApplicationFormAction: { applicationFormResult: { __typename: 'FormSubmitSuccess' },
                                             messages: { blockMessageForCandidateHtml: nil } } } }.to_json
  end
  let(:requests) { [ { url: submit_url, method: 'POST', status: 200, at: 1, frame_url: application_url, body: submit_body, body_error: nil } ] }
  let(:selectors) do
    { success_selectors: Apply::Platform::Ashby::SUCCESS_SELECTORS, failure_selectors: Apply::Platform::Ashby::FAILURE_SELECTORS }
  end

  before do
    ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.new(
      key: 'ashby', confidence: 0.95, captures: { 'slug' => 'preply', 'jid' => '938ee00b-6bf2-4702-b5d5-aa5e8f110155' },
      frame_path: nil, from_alias: false, probable: nil
    ))
    ctx.open_scope!(:submit, session, 5.minutes.from_now)
    ctx.form_root = ApplyMate::Client::Browser::Target.css('#form')
    ctx.fields = [ answer_field(id: 'ashby:_systemfield_email', kind: 'email', target: ApplyMate::Client::Browser::Target.css('#_systemfield_email')) ]
    ctx.scratch.claim_mark = 0
    ctx.scratch.submit_baseline = []
    allow(session).to receive(:network_since).and_return(requests)
  end

  it "finds Ashby's confirmation view in the form root, with the org's copy and no form left" do
    evidence = Apply::Operation::Engine::CollectSubmitEvidence.call(ctx:, **selectors).model

    expect(evidence).to have_attributes(success_dom: Apply::Platform::Ashby::SUCCESS_SELECTORS, failure_dom: [],
                                        form_present: false, field_errors: {}, requests:)
    expect(evidence.text).to start_with('Success Application received! Thank you for taking the first step')
  end

  it 'is submitted on the confirmation view and the FormSubmitSuccess mutation' do
    verdict = described_class.call(ctx:).model

    expect(verdict.status).to eq(:submitted)
    expect(verdict.evidence['signals']).to include('success_dom' => true, 'submit_request' => true)
    expect(verdict.evidence['submit_op']).to eq([ { 'status' => 200, 'body' => 'ok' } ])
  end
end
