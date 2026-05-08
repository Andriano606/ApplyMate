# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Handler::Dou do
  include_context 'honeytech dou'

  # ── HTTP stubs (WebMock) ─────────────────────────────────────────────────────
  before do
    # DOU vacancy page — used by CheckApplyable, FetchApplyType, FetchDetails
    stub_request(:get, HoneytechDou::VACANCY_URL)
      .to_return(status: 200,
                 body: dou_vacancy_html,
                 headers: { 'Content-Type' => 'text/html; charset=utf-8' })

    # Gemini API — stubbed in call order:
    #   1. CheckFormPage  (FetchExternalForm — does the PeopleForce page have a form?)
    #   2. FillForm       (AI fills career_application_form fields)
    #   3. GenerateCv     (AI produces HTML → Grover converts to PDF)
    #   4. CheckSubmitResult (verifies the submit was successful)
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(
        gemini_check_form_page,
        gemini_fill_form,
        gemini_json_response(
          '```html' "\n" \
          "<!DOCTYPE html>\n<html>\n<body>\n<h1>Jane Doe</h1>\n" \
          "<p>AI Animator / Motion Designer</p>\n</body>\n</html>" \
          "\n" '```'
        ),
        gemini_check_submit_result
      )
  end

  # ── Examples ─────────────────────────────────────────────────────────────────
  describe '#call' do
    subject(:run_handler) { described_class.new(apply:).call }

    it 'detects an external apply type from the DOU page' do
      run_handler
      expect(apply.reload.apply_type).to eq('external')
    end

    it 'stores the DOU redirect URL as the external apply URL on the vacancy' do
      run_handler
      expect(vacancy.reload.external_url).to eq(HoneytechDou::DOU_REDIRECT)
    end

    it 'extracts PeopleForce form fields from the HoneyTech apply page' do
      run_handler
      field_names = apply.reload.inputs.map { |i| i['name'] }
      expect(field_names).to include(
        'career_application_form[full_name]',
        'career_application_form[email]',
        'career_application_form[cover_letter]'
      )
    end

    it 'stores AI-filled values in filled_inputs' do
      run_handler
      filled = apply.reload.filled_inputs
      expect(filled).to include(
        hash_including('name' => 'career_application_form[full_name]',
                       'value' => 'Jane Doe'),
        hash_including('name' => 'career_application_form[email]',
                       'value' => 'dev@example.com')
      )
    end

    it 'attaches a generated CV' do
      run_handler
      expect(apply.reload.cv).to be_attached
    end

    it 'completes without an error' do
      run_handler
      reloaded = apply.reload
      expect(reloaded.error).to be_nil
      expect(reloaded.status).to eq('completed')
    end

    it 'navigates the browser to the DOU redirect URL for submission' do
      run_handler
      expect(browser).to have_received(:navigate_to).with(HoneytechDou::DOU_REDIRECT)
    end

    it 'clicks the submit button with the Ukrainian label' do
      run_handler
      expect(browser).to have_received(:click)
        .with(a_string_starting_with('button[type="submit"]'),
              text: a_string_including('Застосувати'))
    end
  end
end
