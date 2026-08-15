# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::External::PrepareSession do
  include_context 'honeytech dou'

  # Vacancy already has external_url set — this operation starts after FetchApplyType resolves it.
  let(:vacancy_external_url) { HoneytechDou::DOU_REDIRECT }
  let(:handler) { Apply::Handler::Dou.new(apply:) }

  describe '#call' do
    subject(:run_operation) { described_class.call(apply:, handler:) }

    it 'navigates the browser to the external URL in the shared session' do
      run_operation
      expect(browser).to have_received(:navigate_to).with(HoneytechDou::DOU_REDIRECT)
    end

    it 'hands the live browser session over to the handler without quitting it' do
      run_operation
      expect(handler.browser).to be(browser)
      expect(browser).not_to have_received(:quit)
    end

    it 'stores snapshot fields with live handles as inputs' do
      run_operation
      inputs = apply.reload.inputs
      expect(inputs.map { |i| i['name'] }).to include(
        'career_application_form[full_name]',
        'career_application_form[email]',
        'career_application_form[cover_letter]',
        'career_application_form[resume]'
      )
      expect(inputs).to all(include('handle'))
    end

    it 'enriches every input with a fingerprint and a role placeholder' do
      run_operation
      inputs = apply.reload.inputs
      expect(inputs).to all(include('role' => nil))
      expect(inputs.map { |i| i['fingerprint'] }).to all(match(/\A[0-9a-f]{40}\z/))
    end

    # The AI exists to FIND a form. A page that already renders fields has
    # nothing to find, and asking anyway once turned a working Ashby form into
    # "AI could not locate an application form page".
    it 'asks the AI nothing when the page already renders fields' do
      run_operation # WebMock would raise on any unstubbed Gemini request
      expect(browser).not_to have_received(:page_digest)
    end

    it 'waits for the form to render before judging the page' do
      run_operation
      expect(browser).to have_received(:wait_for_fields)
    end

    it 'stores the stamped submit button data' do
      run_operation
      reloaded = apply.reload
      expect(reloaded.submit_handle).to eq('submit')
      expect(reloaded.submit_selector).to eq('button[type="submit"].btn.btn-primary')
      expect(reloaded.submit_text).to eq('Застосувати')
    end

    it 'stores the DOU redirect URL as external_url' do
      run_operation
      expect(apply.reload.external_url).to eq(HoneytechDou::DOU_REDIRECT)
    end

    it 'completes without an error' do
      run_operation
      expect(apply.reload.error).to be_nil
    end

    context 'when the form is behind a trigger button' do
      let(:gemini_check_form_page_no_form) do
        gemini_json_response(
          '```json' "\n" \
          '{"has_form":false,"trigger_selector":".actions > a:nth-of-type(1)","form_url":null,"form_selector":null}' "\n" \
          '```'
        )
      end

      before do
        # Nothing rendered even after waiting — this is when the AI earns its keep.
        allow(browser).to receive(:field_count).and_return(0)
        allow(browser).to receive(:wait_for_fields).and_return(false)

        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_check_form_page_no_form, gemini_check_form_page)

        allow(browser).to receive(:click_with_unique_path)
          .with('.actions > a:nth-of-type(1)')
          .and_return('#apply-section > a:nth-of-type(1)')
      end

      it 'clicks the trigger in the same session and stores its unique path' do
        run_operation
        expect(browser).to have_received(:click_with_unique_path).with('.actions > a:nth-of-type(1)')
        expect(apply.reload.trigger_selector).to eq('#apply-section > a:nth-of-type(1)')
      end

      it 'does not navigate a second time' do
        run_operation
        expect(browser).to have_received(:navigate_to).once
      end
    end

    context 'when no form and no trigger can be located' do
      let(:gemini_check_form_page_nothing) do
        gemini_json_response(
          '```json' "\n" \
          '{"has_form":false,"trigger_selector":null,"form_url":null,"form_selector":null}' "\n" \
          '```'
        )
      end

      before do
        allow(browser).to receive(:field_count).and_return(0)
        allow(browser).to receive(:wait_for_fields).and_return(false)

        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_check_form_page_nothing)
      end

      it 'fails the apply with a fetching-form error' do
        expect { run_operation }.to raise_error(/could not locate an application form/)
        expect(apply.reload.status).to eq('failed_fetching_form')
      end
    end
  end
end
