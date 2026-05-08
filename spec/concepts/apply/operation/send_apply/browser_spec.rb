# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::SendApply::Browser do
  include_context 'honeytech dou'

  before do
    apply.update!(
      external_url:    HoneytechDou::DOU_REDIRECT,
      submit_selector: 'button[type="submit"].btn.btn-primary',
      submit_text:     'Застосувати',
      filled_inputs:
    )

    apply.cv.attach(
      io:           StringIO.new('%PDF-1.4 fake-pdf-content'),
      filename:     'Jane_Doe_CV.pdf',
      content_type: 'application/pdf'
    )

    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(gemini_check_submit_result)
  end

  # ── Examples ─────────────────────────────────────────────────────────────────
  describe '#call' do
    subject(:run_operation) { described_class.call(apply:) }

    it 'navigates the browser to the external URL' do
      run_operation
      expect(browser).to have_received(:navigate_to).with(HoneytechDou::DOU_REDIRECT)
    end

    it 'fills non-file inputs with AI-provided values' do
      run_operation
      expect(browser).to have_received(:fill_field)
        .with('[name="career_application_form[full_name]"]', 'Jane Doe', 'input', form_index: 0)
      expect(browser).to have_received(:fill_field)
        .with('[name="career_application_form[email]"]', 'dev@example.com', 'input', form_index: 1)
    end

    it 'skips file inputs during fill_field' do
      run_operation
      expect(browser).not_to have_received(:fill_field)
        .with(a_string_including('resume'), anything, anything, any_args)
    end

    it 'attaches the CV to the file input' do
      run_operation
      expect(browser).to have_received(:attach_file)
        .with(hash_including('type' => 'file', 'name' => 'career_application_form[resume]'),
              a_string_ending_with('.pdf'))
    end

    it 'clicks the submit button' do
      run_operation
      expect(browser).to have_received(:click)
        .with('button[type="submit"].btn.btn-primary', text: 'Застосувати')
    end

    it 'marks the apply as completed' do
      run_operation
      expect(apply.reload.status).to eq('completed')
    end

    it 'completes without an error' do
      run_operation
      expect(apply.reload.error).to be_nil
    end

    context 'when a trigger_selector is set' do
      before { apply.update!(trigger_selector: '#open-modal-btn') }

      it 'clicks the trigger before filling the form' do
        run_operation
        expect(browser).to have_received(:click).with('#open-modal-btn').ordered
        expect(browser).to have_received(:click)
          .with('button[type="submit"].btn.btn-primary', text: 'Застосувати').ordered
      end
    end
  end
end
