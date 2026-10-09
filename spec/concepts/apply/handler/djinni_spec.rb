# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Handler::Djinni do
  include_context 'art of spin djinni'

  let(:http_client) { instance_double(ApplyMate::Client::AsyncHttp) }
  let(:claimed_at_post) { [] }
  let(:vacancy_page) do
    ApplyMate::Client::Response.new(djinni_apply_html, { 'set-cookie' => 'csrftoken=tok-abc; Path=/' }, 200,
                                    ArtOfSpinDjinni::VACANCY_URL)
  end

  before do
    # Every request (reply-button check, details, form fetch, POST) goes through the source's AsyncHttp.
    allow(ApplyMate::Client::AsyncHttp).to receive(:new).and_return(http_client)
    allow(http_client).to receive(:get).and_return(vacancy_page)
    allow(http_client).to receive(:post_multipart) do
      claimed_at_post << Apply.find(apply.id).submit_claimed_at
      ApplyMate::Client::Response.new('', {}, 200, ArtOfSpinDjinni::VACANCY_URL)
    end

    # Gemini, in call order: FillForm, GenerateCv.
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(
      gemini_json_response('```json' "\n" '{"message":"I am an experienced 2D animator."}' "\n" '```'),
      gemini_json_response('```html' "\n" '<html><body><h1>Jane Doe</h1></body></html>' "\n" '```')
    )
  end

  describe '#call' do
    subject(:run_handler) { described_class.new(apply:).call }

    it 'completes through the Runner, one succeeded step row per step' do
      run_handler
      reloaded = apply.reload

      expect(reloaded).to have_attributes(state: 'completed', stage: nil, submitted_via: 'engine')
      expect(reloaded.apply_steps.chronological.map { |step| [ step.key, step.state ] }).to eq(
        %w[check_applyable fetch_apply_type fetch_details fetch_form fill_form generate_cv submit]
          .map { |key| [ key, 'succeeded' ] }
      )
    end

    it 'takes the submit claim before the POST' do
      run_handler

      expect(claimed_at_post).to contain_exactly(be_present)
      expect(apply.reload.submit_claimed_at).to be <= apply.submitted_at
    end

    it 'posts the AI-filled message and the generated CV' do
      run_handler

      expect(http_client).to have_received(:post_multipart).with(
        ArtOfSpinDjinni::VACANCY_URL,
        payload: hash_including('message' => 'I am an experienced 2D animator.',
                                'cv_file' => instance_of(Faraday::Multipart::FilePart)),
        headers: hash_including('Cookie' => include('sessionid=test-session-id'))
      )
    end

    context 'when Djinni redirects the POST to the login page' do
      before do
        allow(http_client).to receive(:post_multipart)
          .and_return(ApplyMate::Client::Response.new('', { 'location' => 'https://djinni.co/login?next=/jobs/' }, 302,
                                                      ArtOfSpinDjinni::VACANCY_URL))
      end

      it 'releases the claim and asks for a fresh session' do
        run_handler

        expect(apply.reload).to be_needs_human
        expect(apply.submit_claimed_at).to be_nil
        expect(apply.failure).to include('code' => 'session_expired', 'stage' => 'submit', 'after_claim' => true)
        expect(apply.apply_steps.chronological.last).to have_attributes(key: 'submit', state: 'failed',
                                                                       error_code: 'session_expired')
      end
    end
  end
end
