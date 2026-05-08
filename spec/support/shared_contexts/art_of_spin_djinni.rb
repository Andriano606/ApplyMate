# frozen_string_literal: true

module ArtOfSpinDjinni
  FIXTURES_DIR = Rails.root.join('spec/fixtures/files/djinni/internal/art of spin')
  VACANCY_URL  = 'https://djinni.co/jobs/813515-2d-animator/'
end

RSpec.shared_context 'art of spin djinni' do
  # ── Fixtures ──────────────────────────────────────────────────────────────────
  let(:djinni_apply_html) { File.read(ArtOfSpinDjinni::FIXTURES_DIR.join('djinny_apply_page.html')) }

  # ── DB records ────────────────────────────────────────────────────────────────
  let(:user) do
    User.create!(email: 'dev@example.com', name: 'Jane Doe',
                 provider: 'google_oauth2', uid: 'uid-art-of-spin-test')
  end

  let(:source) { create(:source, name: 'Djinni', scraper: 'ApplyMate::Scraper::Djinni') }

  let(:vacancy) do
    create(:vacancy, source:, url: ArtOfSpinDjinni::VACANCY_URL,
           title: '2D Animator', company_name: 'Art of Spin')
  end

  let(:source_profile) do
    SourceProfile.create!(user:, source:, name: 'My Djinni Profile',
                          auth_method: :session_id, session_id: 'test-session-id')
  end

  let(:user_profile) do
    UserProfile.create!(user:, name: 'Jane Doe',
                        cv: '2D Animator with 3+ years of experience in Spine and slot games.')
  end

  let(:ai_integration) do
    AiIntegration.create!(user:, provider: 'gemini',
                          model: 'gemini-2.5-flash', api_key: 'test-api-key')
  end

  let(:apply) do
    Apply.create!(
      user:, vacancy:, source_profile:, user_profile:, ai_integration:,
      status: :generating_cv
    )
  end

  # Canonical Djinni apply form fields (post-FillForm state).
  # Includes only the fields relevant to filling and submission;
  # hidden/checkbox ancillaries (save_msg_template, save_profile_cv, etc.) are omitted.
  let(:filled_inputs) do
    [
      { 'name' => 'apply', 'selector' => '[name="apply"]',
        'tag' => 'input', 'type' => 'hidden', 'form_index' => 0,
        'label' => '', 'placeholder' => '', 'value' => 'true' },
      { 'name' => 'message', 'selector' => '#message',
        'tag' => 'textarea', 'type' => 'textarea', 'form_index' => 1,
        'label' => 'Повідомлення', 'placeholder' => '',
        'value' => 'I am an experienced 2D animator with 3+ years in Spine and slot games.' },
      { 'name' => 'cv_file', 'selector' => '#cv_file_input',
        'tag' => 'input', 'type' => 'file', 'form_index' => 4,
        'label' => '', 'placeholder' => '', 'value' => '' },
      { 'name' => 'csrfmiddlewaretoken', 'selector' => '[name="csrfmiddlewaretoken"]',
        'tag' => 'input', 'type' => 'hidden', 'form_index' => 7,
        'label' => '', 'placeholder' => '',
        'value' => 'xcW3TcF3cryx6WqIAuccBTJfa1cXKOOQKiqerZlIAs9HiddqVeobZzyBM3c2NJaz' }
    ]
  end

  # Pre-AI state: same fields with blank values (input to FillForm).
  let(:raw_inputs) { filled_inputs.map { |i| i.merge('value' => '') } }

  # ── Misc stubs ────────────────────────────────────────────────────────────────
  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    allow_any_instance_of(Grover).to receive(:to_pdf).and_return('%PDF-1.4 fake-pdf-content')
  end

  # ── Helper ────────────────────────────────────────────────────────────────────
  def gemini_json_response(text)
    {
      status:  200,
      body:    { candidates: [ { content: { parts: [ { text: } ] } } ] }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    }
  end
end
