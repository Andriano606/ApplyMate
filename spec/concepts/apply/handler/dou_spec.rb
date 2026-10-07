# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Handler::Dou do
  context 'DOU external apply (HoneyTech)' do
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

      it 'completes through the Runner with one succeeded step row per applicable step' do
        run_handler
        reloaded = apply.reload

        expect(reloaded).to have_attributes(state: 'completed', stage: nil, failure: nil, submitted_via: 'engine')
        expect(reloaded.submit_claimed_at).to be_present
        expect(reloaded.submit_claimed_at).to be <= reloaded.submitted_at
        expect(reloaded.apply_steps.chronological.map { |step| [ step.key, step.state, step.attempt ] }).to eq(
          %w[check_applyable fetch_apply_type fetch_form fill_form generate_cv submit].map { |key| [ key, 'succeeded', 1 ] }
        )
      end

      it 'skips the internal-flow steps of an external apply' do
        run_handler
        expect(apply.apply_steps.map(&:position)).to eq([ 0, 1, 2, 4, 5, 6 ])
      end

      it 'navigates the browser to the DOU redirect URL for submission' do
        run_handler
        expect(browser).to have_received(:navigate_to).with(HoneytechDou::DOU_REDIRECT)
      end

      it 'clicks the submit button with the Ukrainian label, once' do
        run_handler
        expect(browser).to have_received(:click).once
        expect(browser).to have_received(:click)
          .with(a_string_starting_with('button[type="submit"]'),
                text: a_string_including('Застосувати'))
      end

      context 'when the vacancy page has no reply button' do
        before do
          allow_any_instance_of(ApplyMate::Scraper::Dou).to receive(:fetch_applyble).and_return(false)
        end

        it 'ends unsupported at check_applyable without fetching the form' do
          run_handler

          expect(apply.reload).to be_unsupported
          expect(apply.applyble).to be(false)
          expect(apply.failure).to include('code' => 'no_application_path', 'stage' => 'check_applyable')
          expect(apply.apply_steps.map(&:key)).to eq([ 'check_applyable' ])
          expect(browser).not_to have_received(:fetch_rendered)
        end
      end
    end
  end

  context 'DOU internal apply (Coidea Agency)' do
    include_context 'coidea dou'

    let(:http_client) { instance_double(ApplyMate::Client::ImpersonateHttp) }
    let(:claimed_at_post) { [] }

    before do
      # Every request (vacancy page checks, form fetch, POST) goes through the source's ImpersonateHttp.
      allow(ApplyMate::Client::ImpersonateHttp).to receive(:new).and_return(http_client)
      allow(http_client).to receive(:get).and_return(
        ApplyMate::Client::Response.new(dou_apply_html, { 'set-cookie' => 'csrftoken=tok; Path=/' }, 200, CoideaDou::VACANCY_URL)
      )
      allow(http_client).to receive(:post_multipart) do
        claimed_at_post << Apply.find(apply.id).submit_claimed_at
        ApplyMate::Client::Response.new('', {}, 200, CoideaDou::VACANCY_URL)
      end

      # Gemini, in call order: FillForm, GenerateCv.
      stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(
        gemini_json_response('```json' "\n" '{"descr":"I am an experienced UI/UX designer."}' "\n" '```'),
        gemini_json_response('```html' "\n" '<html><body><h1>Jane Doe</h1></body></html>' "\n" '```')
      )
    end

    it 'completes over HTTP with the claim taken before the POST' do
      described_class.new(apply:).call
      reloaded = apply.reload

      expect(reloaded).to have_attributes(state: 'completed', apply_type: 'internal', stage: nil)
      expect(claimed_at_post).to contain_exactly(be_present)
      expect(reloaded.submit_claimed_at).to be <= reloaded.submitted_at
      expect(reloaded.apply_steps.chronological.map(&:key))
        .to eq(%w[check_applyable fetch_apply_type fetch_form fill_form generate_cv submit])
      expect(reloaded.apply_steps.map(&:state).uniq).to eq([ 'succeeded' ])
      expect(http_client).to have_received(:post_multipart)
        .with(CoideaDou::VACANCY_URL, payload: hash_including('descr' => 'I am an experienced UI/UX designer.'),
                                      headers: anything)
    end
  end
end
