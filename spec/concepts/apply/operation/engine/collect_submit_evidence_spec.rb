# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::CollectSubmitEvidence do
  let(:ctx) { engine_context(create(:apply)) }

  subject(:evidence) { described_class.call(ctx:).model }

  context 'with a scripted session' do
    let(:html) { '' }
    let(:read_values) { {} }
    let(:missing) { [] }
    let(:session) do
      FakeSession.new(html:, final_url: 'https://jobs.example.com/acme/1/application', read_values:, missing:)
    end
    let(:email) { answer_field(id: 'email', kind: 'email', target: ApplyMate::Client::Browser::Target.css('#email')) }
    let(:name) { answer_field(id: 'name', target: ApplyMate::Client::Browser::Target.css('#name')) }

    before do
      ctx.open_scope!(:submit, session, 5.minutes.from_now)
      ctx.form_root = ApplyMate::Client::Browser::Target.css('#form')
      ctx.fields = [ name, email ]
    end

    context 'when the form is still there and a field reports an error' do
      let(:html) do
        '<body><h1>Lead</h1><div id="form"><input id="name"><input id="email" aria-invalid="true">' \
          '<p role="alert">Email is required</p><button>Submit</button></div></body>'
      end
      let(:read_values) { { '#email' => { 'invalid' => true, 'error_text' => 'Email is required' } } }

      it 'reads the form root text and the errors of the known fields' do
        expect(evidence).to have_attributes(text: 'Email is required Submit', form_present: true,
                                            field_errors: { 'email' => 'Email is required' })
        expect(session.calls_of(:html)).to eq([ [ { frame_path: [] } ] ])
      end
    end

    context 'when a valid field only carries a live-region or describedby text (a hint, an upload notice)' do
      let(:html) { '<body><div id="form"><input id="name"><input id="email"></div></body>' }
      let(:read_values) { { '#email' => { 'invalid' => false, 'error_text' => 'CV.pdf uploaded' } } }

      it 'is no field error' do
        expect(evidence.field_errors).to eq({})
      end
    end

    context 'when a known field is gone' do
      let(:html) { '<body><div id="form"><input id="name"></div></body>' }
      let(:missing) { [ '#email' ] }
      let(:read_values) { { '#name' => { 'invalid' => true } } }

      it 'skips it' do
        expect(evidence.field_errors).to eq('name' => 'invalid')
      end
    end

    context 'when the success message replaced the controls inside the root' do
      let(:html) { '<body><h1>Lead</h1><div id="form"><h2>Thank you for applying</h2></div></body>' }

      it 'has no form and never probes the fields' do
        expect(evidence).to have_attributes(text: 'Thank you for applying', form_present: false, field_errors: {})
        expect(session.calls_of(:probe)).to be_empty
      end
    end

    context 'when the root itself is gone' do
      let(:html) { '<body><h1>Lead</h1><p>Application received.</p></body>' }

      it "reads the frame's body text" do
        expect(evidence).to have_attributes(text: 'Lead Application received.', form_present: false)
      end
    end

    it 'caps the text' do
      allow(session).to receive(:html).and_return("<body><div id=\"form\">#{'a ' * 3_000}</div></body>")

      expect(evidence.text.length).to eq(described_class::TEXT_LIMIT)
    end

    it 'lists the session URL and every frame URL once' do
      allow(session).to receive(:frames).and_return([ { 'url' => 'https://jobs.example.com/acme/1/application' },
                                                      { 'url' => 'https://www.recaptcha.net/anchor' }, { 'url' => '' } ])

      expect(evidence.urls).to eq([ 'https://jobs.example.com/acme/1/application', 'https://www.recaptcha.net/anchor' ])
    end

    it 'reads the requests since the claim with the watched bodies' do
      ctx.scratch.claim_mark = 42
      records = [ { url: 'https://jobs.example.com/api', method: 'POST', status: 200, at: 43, frame_url: nil, body: '{}' } ]
      allow(session).to receive(:network_since).and_return(records)

      expect(evidence.requests).to eq(records)
      expect(session).to have_received(:network_since).with(42, bodies: true)
    end

    it 'counts the requests since the claim still in flight, read before the ended ones' do
      ctx.scratch.claim_mark = 42
      allow(session).to receive(:network_in_flight).and_wrap_original { |original, mark| original.call(mark) + 1 }

      expect(evidence.in_flight).to eq(1)
      expect(session.calls_of(:network_in_flight)).to eq([ [ 42 ] ])
      expect(session.calls.index { |call| call.first == :network_in_flight })
        .to be < session.calls.index { |call| call.first == :network_since }
    end

    it 'has no requests before a claim' do
      expect(evidence).to have_attributes(requests: [], in_flight: 0)
      expect(session.calls_of(:network_since)).to be_empty
      expect(session.calls_of(:network_in_flight)).to be_empty
    end
  end

  context 'after a real submit on the Ashby fixture', :browser do
    it 'reads the success message in the form root and the GraphQL answer since the claim' do
      adopt_fixture_ashby!(ctx)
      in_fixture_scope(ctx, scope: :submit) do |session|
        Apply::Operation::Engine::ReachForm.call(ctx:)
        session.network_watch(ctx.platform.success_evidence.dig(:submit_request, :url))
        ctx.scratch.claim_mark = session.network_mark
        session.click(ApplyMate::Client::Browser::Target.css('button.ashby-application-form-submit-button'))
        session.settle(:submit)

        # The fixture's request starts ~1 s after the click, past the :submit quiet window: VerifySubmit's
        # bounded wait is what sees it.
        expect(Apply::Operation::Engine::VerifySubmit.call(ctx:).model.status).to eq(:submitted)
        expect(evidence).to have_attributes(form_present: false, field_errors: {})
        expect(evidence.text).to start_with('Thank you for applying')
        expect(evidence.requests.sole).to include(status: 200, body: include('"success":true'),
                                                  url: include('/ashby/api/non-user-graphql?op=SubmitApplicationForm'))
        expect(FixtureSite.submissions.sole[:op]).to eq('SubmitApplicationForm')
      end
    end
  end
end
