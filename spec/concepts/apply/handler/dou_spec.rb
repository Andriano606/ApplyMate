# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Handler::Dou do
  include_context 'honeytech dou'

  # ── HTTP stubs ───────────────────────────────────────────────────────────────
  before do
    # DOU vacancy page — used by CheckApplyable, FetchApplyType, FetchDetails.
    # Dou's scraper client is ImpersonateHttp (Chrome TLS to clear Cloudflare); it shells
    # out to curl-impersonate and bypasses WebMock, so stub it at the client level.
    allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
      .with(HoneytechDou::VACANCY_URL, any_args)
      .and_return(
        ApplyMate::Client::Response.new(dou_vacancy_html, {}, 200, HoneytechDou::VACANCY_URL)
      )

    # Gemini API — stubbed in call order. There is no CheckFormPage call: the
    # page already renders fields, so PrepareSession has nothing to ask about.
    #   1. MapFields      (AI maps ambiguous fields to canonical roles)
    #   2. FillForm       (generation batch: cover letter only)
    #   3. GenerateCv     (AI produces HTML → Grover converts to PDF)
    #   4. CheckSubmitResult (verifies the submit was successful)
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(
        gemini_map_fields,
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

    it 'navigates the browser exactly once — fetch and submit share the session' do
      run_handler
      expect(browser).to have_received(:navigate_to).with(HoneytechDou::DOU_REDIRECT).once
    end

    it 'fills the form via live handles from the session snapshot' do
      run_handler
      expect(browser).to have_received(:fill_by_handle).with(0, 'Jane Doe', 'input')
      expect(browser).to have_received(:fill_by_handle).with(1, 'dev@example.com', 'input')
    end

    it 'submits via the stamped submit handle' do
      run_handler
      expect(browser).to have_received(:click_by_handle).with('submit')
    end

    it 'quits the browser exactly once, owned by the handler' do
      run_handler
      expect(browser).to have_received(:quit).once
    end

    it 'saves a form recipe for the employer host after completion' do
      run_handler
      recipe = FormRecipe.find_by(host: 'honeytech.peopleforce.io')
      expect(recipe).to be_present
      expect(recipe.success_count).to eq(1)
      expect(recipe.field_map.map { |f| f['role'] }).to include('email', 'cv_file', 'full_name', 'cover_letter')
    end

    context 'on a second apply to the same employer (recipe replay)' do
      let(:second_apply) do
        Apply.create!(user:, vacancy:, source_profile:, user_profile:, ai_integration:,
                      status: :generating_cv)
      end

      before do
        run_handler # first run learns the recipe

        # Second run needs only the generation batch (cover letter) and the CV —
        # CheckFormPage and MapFields are replaced by the recipe.
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(
            gemini_fill_form,
            gemini_json_response(
              '```html' "\n" \
              "<!DOCTYPE html>\n<html>\n<body>\n<h1>Jane Doe</h1>\n</body>\n</html>" \
              "\n" '```'
            )
          )
      end

      it 'completes via the recipe without navigation or mapping AI calls' do
        described_class.new(apply: second_apply).call

        reloaded = second_apply.reload
        expect(reloaded.status).to eq('completed')
        expect(reloaded.error).to be_nil
        expect(reloaded.fields_source).to eq('recipe')
        expect(FormRecipe.find_by(host: 'honeytech.peopleforce.io').success_count).to eq(2)
      end
    end
  end
end
