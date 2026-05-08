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
    subject(:run_operation) { described_class.call(apply:) }

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
  end
end
