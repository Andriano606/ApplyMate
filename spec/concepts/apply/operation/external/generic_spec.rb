# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::External::Generic do
  include_context 'honeytech dou'

  let(:handler) { Apply::Handler::Dou.new(apply:) }

  before do
    handler.browser = browser

    apply.update!(
      external_url:    HoneytechDou::DOU_REDIRECT,
      resolved_url:    HoneytechDou::PEOPLEFORCE_URL,
      submit_handle:   'submit',
      submit_selector: 'button[type="submit"].btn.btn-primary',
      submit_text:     'Застосувати',
      filled_inputs:
    )

    apply.cv.attach(
      io:           StringIO.new('%PDF-1.4 fake-pdf-content'),
      filename:     'Jane_Doe_CV.pdf',
      content_type: 'application/pdf'
    )
  end

  describe '#call' do
    subject(:run_operation) { described_class.call(apply:, handler:) }

    context 'when the first pass succeeds (deterministic success signal)' do
      it 'fills the pre-resolved inputs via handles, attaches the CV and submits' do
        run_operation
        expect(browser).to have_received(:type_by_handle).with(0, 'Jane Doe')
        expect(browser).to have_received(:attach_file_by_handle).with(4, a_string_ending_with('.pdf'))
        expect(browser).to have_received(:click_by_handle).with('submit')
      end

      it 'completes without any AI call and attaches a screenshot' do
        allow(browser).to receive(:screenshot).and_return('png-bytes')
        run_operation # WebMock would raise on any unstubbed Gemini request
        reloaded = apply.reload
        expect(reloaded.status).to eq('completed')
        expect(reloaded.error).to be_nil
        expect(reloaded.screenshot).to be_attached
      end
    end

    context 'when validation fails and the AI plans a fix' do
      let(:error_state) do
        {
          'url' => HoneytechDou::PEOPLEFORCE_URL,
          'fields' => [
            { 'handle' => 7, 'name' => 'phone', 'accessible_name' => 'Телефон', 'label' => 'Телефон',
              'tag' => 'input', 'type' => 'tel', 'value' => '', 'placeholder' => '' }
          ],
          'buttons' => [ { 'handle' => 'submit', 'text' => 'Застосувати' } ],
          'errors' => [ { 'handle' => 7, 'name' => 'phone', 'message' => 'Вкажіть телефон' } ],
          'alerts' => [], 'form_present' => true, 'captcha' => false, 'password_field' => false
        }
      end

      before do
        allow(browser).to receive(:observe_state).and_return(error_state, browser_observe_state)

        create(:answer_bank, user_profile:, role: 'phone', answer: '+380501234567')

        plan = { 'actions' => [
          { 'op' => 'fill', 'handle' => 7, 'role' => 'phone' },
          { 'op' => 'click', 'handle' => 'submit', 'purpose' => 'submit' }
        ], 'status' => 'in_progress', 'blocked_reason' => nil }
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response("```json\n#{plan.to_json}\n```"))
      end

      it 'fills the failed field with a bank value and re-submits' do
        run_operation
        expect(browser).to have_received(:type_by_handle).with(7, '+380501234567')
        expect(browser).to have_received(:click_by_handle).with('submit').twice
        expect(apply.reload.status).to eq('completed')
      end
    end

    context 'with ATS controls that are not plain text inputs' do
      let(:ats_inputs) do
        [
          { 'name' => 'Autofill from resume', 'accessible_name' => 'Autofill from resume',
            'type' => 'file', 'tag' => 'input', 'handle' => 0, 'role' => 'cv_file', 'value' => '' },
          { 'name' => 'Resume', 'accessible_name' => 'Resume',
            'type' => 'file', 'tag' => 'input', 'handle' => 1, 'role' => 'cv_file', 'value' => '' },
          { 'name' => 'Acknowledge/Confirm', 'accessible_name' => 'Acknowledge/Confirm',
            'type' => 'checkbox', 'tag' => 'input', 'handle' => 2, 'role' => 'consent_gdpr',
            'value' => 'on', 'options' => [ { 'label' => 'Acknowledge/Confirm', 'value' => 'on', 'handle' => 2 } ] },
          { 'name' => 'Newsletter opt-out', 'accessible_name' => 'I do not want the newsletter',
            'type' => 'checkbox', 'tag' => 'input', 'handle' => 3, 'role' => 'consent_marketing',
            'value' => 'false', 'options' => [ { 'label' => 'opt out', 'value' => 'on', 'handle' => 3 } ] },
          { 'name' => 'gender_q', 'accessible_name' => 'Gender identity', 'type' => 'radio',
            'tag' => 'input', 'handle' => 4, 'role' => 'custom_question', 'value' => 'Man',
            'options' => [ { 'label' => 'Woman', 'value' => 'woman', 'handle' => 4 },
                           { 'label' => 'Man', 'value' => 'man', 'handle' => 5 } ] },
          { 'name' => 'based_ua', 'accessible_name' => 'Are you currently based in Ukraine?',
            'type' => 'button_group', 'tag' => 'buttongroup', 'handle' => 'grp-0',
            'role' => 'custom_question', 'value' => 'Yes',
            'options' => [ { 'label' => 'Yes', 'value' => 'Yes', 'handle' => 'opt-0-0' },
                           { 'label' => 'No', 'value' => 'No', 'handle' => 'opt-0-1' } ] }
        ]
      end

      before do
        allow(browser).to receive(:set_checkbox_by_handle)
        apply.update!(filled_inputs: ats_inputs)
      end

      it 'ticks a consent checkbox instead of writing a value into it' do
        run_operation
        expect(browser).to have_received(:set_checkbox_by_handle).with(2, true)
        expect(browser).not_to have_received(:type_by_handle).with(2, anything)
      end

      it 'leaves an already-unticked opt-out checkbox alone' do
        run_operation
        expect(browser).not_to have_received(:set_checkbox_by_handle).with(3, anything)
      end

      it 'clicks the radio option matching the answer, not the first one' do
        run_operation
        expect(browser).to have_received(:click_by_handle).with(5)
        expect(browser).not_to have_received(:click_by_handle).with(4)
      end

      it 'clicks the matching option of a button-built question' do
        run_operation
        expect(browser).to have_received(:click_by_handle).with('opt-0-0')
        expect(browser).not_to have_received(:click_by_handle).with('opt-0-1')
      end

      it 'uploads the CV to the resume field, never to the autofill parser' do
        run_operation
        expect(browser).to have_received(:attach_file_by_handle).with(1, a_string_ending_with('.pdf'))
        expect(browser).not_to have_received(:attach_file_by_handle).with(0, anything)
      end
    end

    context 'when the site refuses the submission (Ashby anti-spam)' do
      let(:rejected_state) do
        browser_observe_state.merge(
          'alerts' => [ "We couldn't submit your application",
                        'Your application submission was flagged as possible spam. ' \
                        'If you believe this was a mistake please submit your application again' ],
          'form_present' => true,
          'url' => 'https://jobs.ashbyhq.com/preply/a9419d80/application'
        )
      end

      before { allow(browser).to receive(:observe_state).and_return(rejected_state) }

      it 'stops immediately instead of re-clicking submit' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError)
        # exactly one click: the initial submit, none from the loop
        expect(browser).to have_received(:click_by_handle).with('submit').once
      end

      it 'hands the apply to the user with the site message preserved' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError)
        reloaded = apply.reload
        expect(reloaded.status).to eq('needs_review')
        expect(reloaded.error).to include('відхилив автоматичну відправку')
        expect(reloaded.error).to include('flagged as possible spam')
      end

      it 'spends no AI tokens on planning further actions' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError)
        # WebMock would raise on an unstubbed Gemini request
      end
    end

    context 'when a rejection notice also contains success-looking wording' do
      before do
        allow(browser).to receive(:observe_state).and_return(
          browser_observe_state.merge(
            'alerts' => [ 'Your application was not submitted — submission was rejected' ],
            'form_present' => true, 'url' => HoneytechDou::PEOPLEFORCE_URL
          )
        )
      end

      it 'is never mistaken for a completed application' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError)
        expect(apply.reload.status).not_to eq('completed')
      end
    end

    context 'when a captcha challenge is visible' do
      before do
        allow(browser).to receive(:observe_state).and_return(
          browser_observe_state.merge('captcha' => true, 'form_present' => true, 'alerts' => [],
                                      'url' => HoneytechDou::PEOPLEFORCE_URL)
        )
      end

      it 'stops with blocked_captcha before spending AI tokens' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError)
        reloaded = apply.reload
        expect(reloaded.status).to eq('blocked_captcha')
        expect(reloaded.error).to include('Captcha')
      end
    end

    context 'when the page redirects to a login wall' do
      before do
        allow(browser).to receive(:observe_state).and_return(
          browser_observe_state.merge('url' => 'https://employer.com/users/sign-in', 'alerts' => [],
                                      'form_present' => true)
        )
      end

      it 'stops with blocked_login' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError)
        expect(apply.reload.status).to eq('blocked_login')
      end
    end

    context 'when the AI reports an unnamed reason' do
      before do
        allow(browser).to receive(:observe_state).and_return(
          browser_observe_state.merge('alerts' => [], 'form_present' => true,
                                      'url' => 'https://employer.com/apply')
        )
        plan = { 'actions' => [], 'status' => 'blocked', 'blocked_reason' => 'other' }
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response("```json\n#{plan.to_json}\n```"))
      end

      # A bare "cannot be automated" leaves the user with nothing to act on.
      it 'hands over to manual submission and names the page' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError)
        reloaded = apply.reload
        expect(reloaded.status).to eq('needs_review')
        expect(reloaded.error).to include('https://employer.com/apply')
      end
    end

    context 'when the AI itself reports an account wall' do
      before do
        allow(browser).to receive(:observe_state).and_return(
          browser_observe_state.merge('alerts' => [], 'form_present' => true,
                                      'url' => HoneytechDou::PEOPLEFORCE_URL)
        )
        plan = { 'actions' => [], 'status' => 'blocked', 'blocked_reason' => 'requires_account' }
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response("```json\n#{plan.to_json}\n```"))
      end

      it 'stops with blocked_requires_account' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError)
        expect(apply.reload.status).to eq('blocked_requires_account')
      end
    end

    context 'when the form never submits' do
      before do
        allow(browser).to receive(:observe_state).and_return(
          browser_observe_state.merge('alerts' => [], 'form_present' => true,
                                      'url' => HoneytechDou::PEOPLEFORCE_URL)
        )
        plan = { 'actions' => [ { 'op' => 'click', 'handle' => 'submit', 'purpose' => 'submit' } ],
                 'status' => 'in_progress', 'blocked_reason' => nil }
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response("```json\n#{plan.to_json}\n```"))
      end

      it 'gives up after MAX_ITERATIONS into needs_review with the observed fields saved' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError, /not submitted after/)
        reloaded = apply.reload
        expect(reloaded.status).to eq('needs_review')
        expect(reloaded.review_fields).to eq([])
      end
    end

    context 'when the AI has no actions to offer' do
      let(:open_fields) do
        [ { 'handle' => 3, 'name' => 'security_code', 'accessible_name' => 'Код із СМС',
            'tag' => 'input', 'type' => 'text', 'value' => '', 'fingerprint' => 'fp-sms' } ]
      end

      before do
        allow(browser).to receive(:observe_state).and_return(
          browser_observe_state.merge('alerts' => [], 'form_present' => true,
                                      'url' => HoneytechDou::PEOPLEFORCE_URL,
                                      'fields' => open_fields)
        )
        plan = { 'actions' => [], 'status' => 'in_progress', 'blocked_reason' => nil }
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_json_response("```json\n#{plan.to_json}\n```"))
      end

      it 'stores the open fields for the review UI and sets needs_review' do
        expect { run_operation }.to raise_error(Apply::Operation::Base::BlockedError, /no actions/)
        reloaded = apply.reload
        expect(reloaded.status).to eq('needs_review')
        expect(reloaded.review_fields).to include(hash_including('name' => 'security_code'))
      end
    end

    context 'when the session was lost (job retry)' do
      let(:browser_snapshot) do
        {
          'fields' => raw_inputs.map { |i| i.merge('handle' => i['handle'] + 10) },
          'submit' => { 'handle' => 'submit', 'text' => 'Застосувати',
                        'selector' => 'button[type="submit"].btn.btn-primary' }
        }
      end

      before { allow(browser).to receive(:alive?).and_return(false) }

      it 'rebuilds the session and re-maps values onto fresh handles' do
        run_operation
        expect(browser).to have_received(:navigate_to).with(HoneytechDou::DOU_REDIRECT)
        expect(browser).to have_received(:type_by_handle).with(10, 'Jane Doe')
        expect(browser).to have_received(:click).with('button[type="submit"].btn.btn-primary', text: 'Застосувати')
        expect(apply.reload.status).to eq('completed')
      end
    end
  end
end
