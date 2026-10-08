require 'rails_helper'

RSpec.describe Apply::Operation::SendApply::Browser do
  include_context 'honeytech dou'

  let(:submit_css) { 'button[type="submit"].btn.btn-primary' }
  let(:submit_target) do
    ApplyMate::Client::Browser::Target.new(
      frame_path: [], strategies: [ { 'css' => submit_css, 'has_text' => 'Застосувати' }, { 'css' => submit_css } ],
      root: nil, readonly: false
    )
  end
  let(:full_name_target) do
    ApplyMate::Client::Browser::Target.new(
      frame_path: [], root: nil, readonly: false,
      strategies: [ { 'css' => '[name="career_application_form[full_name]"]' },
                    { 'css' => described_class::FORM_CONTROLS_CSS, 'nth' => 0 } ]
    )
  end

  before do
    apply.update!(
      external_url:    HoneytechDou::DOU_REDIRECT,
      submit_selector: submit_css,
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

  def clicked_targets
    session.calls_of(:click).map(&:first)
  end

  describe '#call' do
    subject(:run_operation) { described_class.call(ctx:) }

    let(:ctx) { engine_context(apply) }

    it 'opens a humanized session within the run deadline, owned by this apply' do
      run_operation

      options = session.open_options.sole
      expect(options).to include(humanize: true, identity: apply.hashid,
                                 owner: ApplyMate::Client::Browser::Session.owner_for(apply))
      expect(options[:deadline]).to be <= ctx.deadline_at
    end

    it 'navigates the browser to the external URL' do
      run_operation
      expect(session.calls).to include([ :goto, HoneytechDou::DOU_REDIRECT ])
    end

    it 'fills non-file inputs with AI-provided values, settling after each key input' do
      run_operation

      expect(session.calls_of(:fill)).to contain_exactly(
        [ full_name_target, 'Jane Doe' ],
        [ have_attributes(strategies: [ { 'css' => '[name="career_application_form[email]"]' },
                                        { 'css' => described_class::FORM_CONTROLS_CSS, 'nth' => 1 } ]),
          user_email ]
      )
      expect(session.calls.count([ :settle, :key ])).to eq(2)
    end

    it 'reads every filled value back' do
      run_operation
      expect(session.calls).to include([ :probe, :read_value, full_name_target ])
    end

    it 'never fills the file input' do
      run_operation
      expect(session.calls_of(:fill).map { |target, _| target.strategies.first['css'] })
        .not_to include(a_string_including('resume'))
    end

    it 'uploads the CV to the file input (stored selector, any file input, position)' do
      run_operation

      target, path = session.calls_of(:upload).sole
      expect(target.strategies).to eq([ { 'css' => '[name="career_application_form[resume]"]' },
                                        { 'css' => 'input[type="file"]' },
                                        { 'css' => described_class::FORM_CONTROLS_CSS, 'nth' => 4 } ])
      expect(path).to end_with('.pdf')
      expect(session.calls).to include([ :settle, :file ])
    end

    it 'clicks the submit button by selector and text, then settles for the submit' do
      run_operation

      expect(clicked_targets).to eq([ submit_target ])
      expect(session.calls.index([ :settle, :submit ])).to be > session.calls.index([ :click, submit_target ])
    end

    it 'checks the submit button is visible, then takes the claim right before clicking it' do
      claimed_at_check = :unset
      claimed_at_click = nil
      session.on(:present?) { claimed_at_check = Apply.find(apply.id).submit_claimed_at }
      session.on(:click) { claimed_at_click = Apply.find(apply.id).submit_claimed_at }

      run_operation

      expect(session.calls).to include([ :present?, submit_target, { visibility: :required } ])
      expect(claimed_at_check).to be_nil
      expect(claimed_at_click).to be_present
    end

    it 'takes a full-page screenshot and verifies the page after the submit' do
      run_operation
      expect(session.calls.last(2)).to eq([ [ :screenshot, { full_page: true } ], [ :html, { frame_path: [] } ] ])
    end

    it 'completes the run with the claim taken first' do
      run_engine_step(apply, described_class)

      expect(apply).to be_completed
      expect(apply.submitted_at).to be >= apply.submit_claimed_at
      expect(apply.apply_steps.sole).to have_attributes(stage: 'submit', state: 'succeeded')
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
      let(:session) do
        FakeSession.new(html: honeytech_apply_html, final_url: HoneytechDou::PEOPLEFORCE_URL, missing: [ submit_css ])
      end

      it 'fails with target_not_found before the claim, without clicking' do
        run_engine_step(apply, described_class)

        expect(apply).to be_failed
        expect(apply.submit_claimed_at).to be_nil
        expect(apply.failure).to include('code' => 'target_not_found', 'after_claim' => false, 'detail' => submit_css)
        expect(session.calls_of(:click)).to be_empty
      end
    end

    context 'when a filled value does not read back' do
      let(:session) do
        FakeSession.new(html: honeytech_apply_html, final_url: HoneytechDou::PEOPLEFORCE_URL,
                        read_values: { '[name="career_application_form[email]"]' => '' })
      end

      it 'fails with required_field_unfillable before the claim, without clicking' do
        run_engine_step(apply, described_class)

        expect(apply).to be_failed
        expect(apply.submit_claimed_at).to be_nil
        expect(apply.failure).to include('code' => 'required_field_unfillable', 'after_claim' => false,
                                         'detail' => 'career_application_form[email]')
        expect(session.calls_of(:click)).to be_empty
      end
    end

    context 'when a single-line input dropped the line breaks of the value' do
      let(:session) do
        FakeSession.new(html: honeytech_apply_html, final_url: HoneytechDou::PEOPLEFORCE_URL,
                        read_values: { '[name="career_application_form[full_name]"]' => 'JaneDoe ' })
      end

      before do
        apply.update!(filled_inputs: [ filled_inputs.first.merge('value' => "Jane\r\nDoe") ])
      end

      it 'accepts the value (browser sanitisation, as before)' do
        expect(run_engine_step(apply, described_class)).to be_completed
      end
    end

    context 'when the form has hidden inputs, checkboxes and selects' do
      before do
        apply.update!(filled_inputs: [
          { 'name' => 'authenticity_token', 'selector' => '[name="authenticity_token"]', 'tag' => 'input',
            'type' => 'hidden', 'form_index' => 0, 'value' => 'page-token' },
          { 'name' => 'consent', 'selector' => '#consent', 'tag' => 'input', 'type' => 'checkbox',
            'form_index' => 1, 'value' => '1' },
          { 'name' => 'country', 'selector' => '#country', 'tag' => 'select', 'type' => 'select',
            'form_index' => 2, 'value' => 'UA' }
        ])
      end

      it 'leaves hidden inputs and checkboxes to the page and chooses the select option by value' do
        run_operation

        expect(session.calls_of(:fill)).to be_empty
        expect(session.calls_of(:select).sole)
          .to match([ have_attributes(strategies: include({ 'css' => '#country' })), { value: 'UA', label: nil } ])
      end
    end

    context 'when the submit button vanishes between the check and the click' do
      before do
        session.on(:click) do |target|
          raise ApplyMate::Client::Browser::TargetNotFound.new(target) if target == submit_target
        end
      end

      it 'keeps the claim (submit_unverified): the click may have landed' do
        expect(run_engine_step(apply, described_class)).to be_submit_unverified
        expect(apply.failure).to include('code' => 'target_not_found', 'after_claim' => true, 'detail' => submit_css)
      end
    end

    context 'when the trigger is missing' do
      let(:session) do
        FakeSession.new(html: honeytech_apply_html, final_url: HoneytechDou::PEOPLEFORCE_URL,
                        missing: [ '#open-modal-btn' ])
      end

      before { apply.update!(trigger_selector: '#open-modal-btn') }

      it 'fails with target_not_found and no claim' do
        expect(run_engine_step(apply, described_class)).to be_failed
        expect(apply.submit_claimed_at).to be_nil
        expect(apply.failure).to include('code' => 'target_not_found', 'detail' => '#open-modal-btn')
        expect(session.calls_of(:fill)).to be_empty
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
        expect(clicked_targets).to eq([ submit_target ])
      end
    end

    context 'when a trigger_selector is set' do
      before { apply.update!(trigger_selector: '#open-modal-btn') }

      it 'clicks the trigger, settles and waits for the form before filling it' do
        run_operation

        trigger = ApplyMate::Client::Browser::Target.css('#open-modal-btn')
        expect(clicked_targets).to eq([ trigger, submit_target ])
        click_at = session.calls.index([ :click, trigger ])
        expect(session.calls[click_at + 1, 2]).to eq([
          [ :settle, :click ],
          [ :ready?, ApplyMate::Client::Browser::Target.css('form'), { timeout: 10, min_fields: 1 } ]
        ])
        expect(session.calls.index { |call| call.first == :fill }).to be > click_at
      end
    end
  end
end
