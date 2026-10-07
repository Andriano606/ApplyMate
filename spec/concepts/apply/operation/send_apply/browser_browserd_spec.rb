# frozen_string_literal: true

require 'rails_helper'

# The legacy browser steps on the REAL Session (browserd + Camoufox) against FixtureSite: FetchExternalForm renders
# and extracts the form, SendApply::Browser fills it (read-back), uploads the CV, claims and clicks submit. Only
# Gemini is stubbed; its verify request carries the page after the click, which proves the POST landed.
RSpec.describe Apply::Operation::SendApply::Browser, :browser do
  include_context 'honeytech dou'

  let(:gemini) { /generativelanguage\.googleapis\.com.*generateContent/ }
  let(:ctx) { engine_context(apply) }

  before do
    allow(ApplyMate::Client::Browser::Session).to receive(:open).and_call_original # undo the context's FakeSession
    apply.cv.attach(io: StringIO.new('%PDF-1.4 fake-pdf-content'), filename: 'Jane_Doe_CV.pdf',
                    content_type: 'application/pdf')
  end

  def fill_values(values)
    apply.reload.update!(filled_inputs: apply.inputs.map { |input| input.merge('value' => values.fetch(input['name'], input['value'])) })
  end

  def page_after_submit_sent_to_ai?
    a_request(:post, gemini).with { |request| request.body.include?('Thank you for applying') }
  end

  context 'with the form on the page' do
    let(:vacancy_external_url) { FixtureSite.url('/form.html') }

    before do
      stub_request(:post, gemini).to_return(
        gemini_json_response('{"has_form":true,"trigger_selector":null,"form_url":null,"form_selector":"#apply"}'),
        gemini_check_submit_result
      )
    end

    it 'extracts, fills with read-back, uploads the CV and submits once after the claim' do
      Apply::Operation::Ai::FetchExternalForm.call(ctx:)
      expect(apply.reload).to have_attributes(submit_selector: 'button[type="submit"].primary',
                                              submit_text: 'Submit application')

      fill_values('full_name' => 'Jane Doe', 'email' => 'jane@example.com', 'cover' => "Line one\nLine two",
                  'experience' => 'senior', 'consent' => '1')
      described_class.call(ctx:)

      expect(apply.reload.submit_claimed_at).to be_present
      expect(apply.screenshot).to be_attached
      expect(page_after_submit_sent_to_ai?).to have_been_made.once
    end
  end

  context 'with the form behind a trigger' do
    let(:vacancy_external_url) { FixtureSite.url('/trigger.html') }

    before do
      stub_request(:post, gemini).to_return(
        gemini_json_response('{"has_form":false,"trigger_selector":"#open-form","form_url":null,"form_selector":null}'),
        gemini_json_response('{"has_form":true,"trigger_selector":null,"form_url":null,"form_selector":"#late-form"}'),
        gemini_check_submit_result
      )
    end

    it 'waits for the late form after the click, then replays the trigger and submits' do
      Apply::Operation::Ai::FetchExternalForm.call(ctx:)
      expect(apply.reload).to have_attributes(trigger_selector: '#open-form', submit_text: 'Send')
      expect(apply.inputs.map { |input| input['name'] }).to eq(%w[late_name late_email])

      fill_values('late_name' => 'Jane Doe', 'late_email' => 'jane@example.com')
      described_class.call(ctx:)

      expect(page_after_submit_sent_to_ai?).to have_been_made.once
    end
  end

  context 'when a value does not stick' do
    let(:vacancy_external_url) { FixtureSite.url('/form.html') }

    before do
      stub_request(:post, gemini).to_return(
        gemini_json_response('{"has_form":true,"trigger_selector":null,"form_url":null,"form_selector":"#apply"}')
      )
    end

    it 'halts with required_field_unfillable before the claim' do
      Apply::Operation::Ai::FetchExternalForm.call(ctx:)
      fill_values('full_name' => 'J' * 41) # form.html caps full_name at maxlength=40, so the read-back differs

      expect { described_class.call(ctx:) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :required_field_unfillable, detail: 'full_name')
      }
      expect(apply.reload.submit_claimed_at).to be_nil
    end
  end
end
