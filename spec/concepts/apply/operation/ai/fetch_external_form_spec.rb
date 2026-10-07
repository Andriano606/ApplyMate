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

    it 'fetches the external page via the browser' do
      run_operation
      expect(browser).to have_received(:fetch_rendered).with(HoneytechDou::DOU_REDIRECT)
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

    it 'quits the browser' do
      run_operation
      expect(browser).to have_received(:quit)
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
        expect(browser).not_to have_received(:fetch_rendered)
      end
    end

    context 'when the rendered page is empty' do
      before { allow(browser).to receive(:fetch_rendered).and_return([ HoneytechDou::PEOPLEFORCE_URL, '', '' ]) }

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

    context 'when the trigger reveals nothing' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(
          gemini_json_response('{"has_form":false,"trigger_selector":"#apply","form_url":null,"form_selector":null}')
        )
        allow(browser).to receive(:click_and_fetch).and_return([ HoneytechDou::PEOPLEFORCE_URL, '', '', nil ])
      end

      it 'does not find the target' do
        expect(halt_code).to eq(:target_not_found)
      end
    end
  end
end
