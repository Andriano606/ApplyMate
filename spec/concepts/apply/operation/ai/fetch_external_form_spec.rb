# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Ai::FetchExternalForm do
  include_context 'honeytech dou'

  # Vacancy already has external_url set — this operation starts after FetchApplyType resolves it.
  let(:vacancy_external_url) { HoneytechDou::DOU_REDIRECT }

  # ── HTTP stubs (WebMock) ─────────────────────────────────────────────────────
  before do
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(gemini_check_form_page)
  end

  # ── Examples ─────────────────────────────────────────────────────────────────
  describe '#call' do
    subject(:run_operation) { described_class.call(ctx: engine_context(apply)) }

    it 'renders the external page in a session without humanize, within the run deadline' do
      ctx = engine_context(apply)
      described_class.call(ctx:)

      expect(session.open_options.sole).to include(humanize: false, identity: apply.hashid,
                                                   owner: ApplyMate::Client::Browser::Session.owner_for(apply))
      expect(session.open_options.sole[:deadline]).to be <= ctx.deadline_at
      expect(session.calls).to include([ :goto, HoneytechDou::DOU_REDIRECT ])
      expect(session.calls_of(:click)).to be_empty
    end

    it 'populates inputs with PeopleForce form fields' do
      run_operation
      field_names = apply.reload.inputs.map { |i| i['name'] }
      expect(field_names).to include(
       "authenticity_token",
       "career_application_form[vacancy_id]",
       "career_application_form[source_id]",
       "career_application_form[full_name]",
       "career_application_form[email]",
       "career_application_form[phone_numbers][]",
       "career_application_form[phone_numbers][]",
       "career_application_form[cover_letter]",
       "career_application_form[resume]",
       "career_application_form[telegram_username]",
       "career_application_form[urls][]"
      )
    end

    it 'resolves the form action to an absolute URL' do
      run_operation
      expect(apply.reload.action).to eq(
        'https://honeytech.peopleforce.io/careers/v/202646-ai-animator-motion-designer/a'
      )
    end

    it 'stores the HTTP method from the form element' do
      run_operation
      expect(apply.reload.http_method).to eq('post')
    end

    it 'stores a submit selector derived from the submit button' do
      run_operation
      expect(apply.reload.submit_selector).to start_with('button[type="submit"]')
    end

    it 'stores the DOU redirect URL as external_url' do
      run_operation
      expect(apply.reload.external_url).to eq(HoneytechDou::DOU_REDIRECT)
    end

    context 'when the page sets cookies' do
      let(:session) do
        FakeSession.new(html: honeytech_apply_html, final_url: HoneytechDou::PEOPLEFORCE_URL, cookies: 'sid=abc')
      end

      it 'stores the session cookies with the form' do
        run_operation
        expect(apply.reload.form_data).to include('cookies' => 'sid=abc')
      end
    end

    context 'when the AI names a relative form URL on a public host' do
      let(:form_url) { 'https://honeytech.peopleforce.io/careers/apply' }

      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(
          gemini_json_response('{"has_form":false,"trigger_selector":null,"form_url":"/careers/apply","form_selector":null}'),
          gemini_check_form_page
        )
        allow_any_instance_of(Resolv).to receive(:getaddresses).with('honeytech.peopleforce.io').and_return([ '104.18.1.1' ])
        allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get).with(form_url, follow_redirects: true)
          .and_return(ApplyMate::Client::AsyncHttp::Response.new(honeytech_apply_html, {}, 200, form_url))
      end

      it 'resolves it against the page, passes the guard and fetches the form over HTTP' do
        described_class.call(ctx: engine_context(apply))
        expect(apply.reload.inputs.map { |i| i['name'] }).to include('career_application_form[email]')
      end
    end
  end

  describe 'halts' do
    def halt_code
      described_class.call(ctx: engine_context(apply))
    rescue Apply::Operation::Engine::Halt => e
      e.code
    end

    context 'without an external URL on the vacancy' do
      let(:vacancy_external_url) { nil }

      it 'has no application path' do
        expect(halt_code).to eq(:no_application_path)
        expect(session.open_options).to be_empty
      end
    end

    context 'when the rendered page is empty' do
      let(:session) { FakeSession.new(html: '', final_url: HoneytechDou::PEOPLEFORCE_URL) }

      it 'does not find the target' do
        expect(halt_code).to eq(:target_not_found)
      end
    end

    context 'when the AI finds neither a form, a trigger nor a form URL' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(
          gemini_json_response('{"has_form":false,"trigger_selector":null,"form_url":null,"form_selector":null}')
        )
      end

      it 'is not a form' do
        expect(halt_code).to eq(:not_a_form)
      end

      it 'ends the run unsupported' do
        run_engine_step(apply, described_class)

        expect(apply).to be_unsupported
        expect(apply.failure).to include('code' => 'not_a_form', 'stage' => 'fetch_form')
      end
    end

    context 'when the AI names a form URL on a private host' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(
          gemini_json_response(
            '{"has_form":false,"trigger_selector":null,"form_url":"http://127.0.0.1:3000/apply","form_selector":null}'
          )
        )
      end

      it 'ends the run unsupported with private_address (the real PublicAddressGuard), without fetching it' do
        run_engine_step(apply, described_class)

        expect(apply).to be_unsupported
        expect(apply.failure).to include('code' => 'private_address', 'stage' => 'fetch_form')
        expect(a_request(:get, %r{127\.0\.0\.1})).not_to have_been_made
      end
    end

    context 'when the AI names a trigger' do
      let(:trigger) { ApplyMate::Client::Browser::Target.css('#apply') }

      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(
          gemini_json_response('{"has_form":false,"trigger_selector":"#apply","form_url":null,"form_selector":null}'),
          gemini_check_form_page
        )
      end

      it 'clicks it on a fresh load, settles, waits for the form and stores the AI selector' do
        described_class.call(ctx: engine_context(apply))

        click_at = session.calls.index([ :click, trigger ])
        expect(session.calls[click_at - 1]).to eq([ :goto, HoneytechDou::DOU_REDIRECT ])
        expect(session.calls[click_at + 1, 2]).to eq([
          [ :settle, :click ],
          [ :ready?, ApplyMate::Client::Browser::Target.css('form'), { timeout: 10, min_fields: 1 } ]
        ])
        expect(apply.reload.trigger_selector).to eq('#apply')
      end

      context 'when it is not on the page' do
        let(:session) do
          FakeSession.new(html: honeytech_apply_html, final_url: HoneytechDou::PEOPLEFORCE_URL, missing: [ '#apply' ])
        end

        it 'does not find the target' do
          expect(halt_code).to eq(:target_not_found)
        end
      end
    end
  end
end
