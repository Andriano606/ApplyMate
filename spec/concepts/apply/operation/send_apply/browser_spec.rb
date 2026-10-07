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
    subject(:run_operation) { described_class.call(ctx: engine_context(apply)) }

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

    it 'takes the submit claim right before clicking submit' do
      claimed_at_click = nil
      allow(browser).to receive(:click).with('button[type="submit"].btn.btn-primary', text: 'Застосувати') do
        claimed_at_click = Apply.find(apply.id).submit_claimed_at
        true
      end

      run_operation

      expect(claimed_at_click).to be_present
      expect(browser).to have_received(:attempt_recaptcha_refresh).ordered
      expect(browser).to have_received(:click).ordered
    end

    it 'completes the run with the claim taken first' do
      run_engine_step(apply, described_class)

      expect(apply).to be_completed
      expect(apply.submitted_at).to be >= apply.submit_claimed_at
      expect(apply.apply_steps.sole).to have_attributes(stage: 'submit', state: 'succeeded')
      expect(browser).to have_received(:quit)
    end

    context 'when the verify call comes back without text (thinking ate the cap)' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(
          status:  200,
          body:    { candidates:    [ { finishReason: 'MAX_TOKENS', content: { parts: [] } } ],
                     usageMetadata: { promptTokenCount: 10, thoughtsTokenCount: 1_024 } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )
      end

      it 'ends submit_unverified through the Runner mapping (invalid_ai_output + claim rule), never completed' do
        run_engine_step(apply, described_class)

        expect(apply).to be_submit_unverified
        expect(apply.submit_claimed_at).to be_present
        expect(apply.submitted_at).to be_nil
        expect(apply.failure).to include('code' => 'invalid_ai_output', 'stage' => 'submit', 'after_claim' => true)
      end
    end

    context 'when the verdict is unparseable' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response('I think it worked'))
      end

      it 'ends submit_unverified with invalid_ai_output' do
        expect(run_engine_step(apply, described_class)).to be_submit_unverified
        expect(apply.failure).to include('code' => 'invalid_ai_output', 'after_claim' => true)
      end
    end

    context 'when the verdict says the submission failed' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response('{"success":false,"reason":"Error banner"}'))
      end

      it 'halts with a non-definitive validation_rejected' do
        expect { run_operation }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
          expect(halt).to have_attributes(code: :validation_rejected, detail: 'Error banner')
          expect(halt.releases_claim?).to be(false)
        }
      end

      it 'keeps the claim: an AI verdict alone never releases it' do
        run_engine_step(apply, described_class)

        expect(apply).to be_submit_unverified
        expect(apply.submit_claimed_at).to be_present
        expect(apply.failure).to include('code' => 'validation_rejected', 'detail' => 'Error banner')
        expect(apply).not_to be_resumable
      end
    end

    context 'when the submit button is missing' do
      before { allow(browser).to receive(:clickable?).and_return(false) }

      it 'fails with target_not_found before the claim, without clicking' do
        run_engine_step(apply, described_class)

        expect(apply).to be_failed
        expect(apply.submit_claimed_at).to be_nil
        expect(apply.failure).to include('code' => 'target_not_found', 'after_claim' => false,
                                         'detail' => 'button[type="submit"].btn.btn-primary')
        expect(browser).not_to have_received(:click)
      end
    end

    context 'when the submit button vanishes between the check and the click' do
      before do
        allow(browser).to receive(:click).with('button[type="submit"].btn.btn-primary', text: 'Застосувати')
                                         .and_return(false)
      end

      it 'keeps the claim (submit_unverified): the click may have landed' do
        expect(run_engine_step(apply, described_class)).to be_submit_unverified
        expect(apply.failure).to include('code' => 'target_not_found', 'after_claim' => true)
      end
    end

    context 'when the trigger is missing' do
      before do
        apply.update!(trigger_selector: '#open-modal-btn')
        allow(browser).to receive(:click).with('#open-modal-btn').and_return(false)
      end

      it 'fails with target_not_found and no claim' do
        expect(run_engine_step(apply, described_class)).to be_failed
        expect(apply.submit_claimed_at).to be_nil
        expect(apply.failure).to include('code' => 'target_not_found', 'detail' => '#open-modal-btn')
      end
    end

    context 'after a claimed run' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response('{"success":false,"reason":"Error banner"}'))
      end

      it 'cannot submit again: a claimed apply is not startable' do
        handler_class = Class.new(Apply::Handler::Base) { add_step Apply::Operation::SendApply::Browser }
        handler_class.new(apply:).call
        expect(apply.reload).to be_submit_unverified

        expect { handler_class.new(apply:).call }.not_to change(ApplyStep, :count)
        expect(apply.reload).to have_attributes(state: 'submit_unverified', attempt: 1)
        expect(browser).to have_received(:click).with('button[type="submit"].btn.btn-primary', text: 'Застосувати').once
      end
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
