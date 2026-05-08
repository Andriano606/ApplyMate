# frozen_string_literal: true

module CoideaDou
  FIXTURES_DIR = Rails.root.join('spec/fixtures/files/dou/internal/agency coidea')
  VACANCY_URL  = 'https://jobs.dou.ua/companies/coidea-agency/vacancies/356740/'
end

RSpec.shared_context 'coidea dou' do
  # ── Fixtures ──────────────────────────────────────────────────────────────────
  let(:dou_apply_html) { File.read(CoideaDou::FIXTURES_DIR.join('dou_apply_page.html')) }

  # ── DB records ────────────────────────────────────────────────────────────────
  let(:user) do
    User.create!(email: 'dev@example.com', name: 'Jane Doe',
                 provider: 'google_oauth2', uid: 'uid-coidea-test')
  end

  let(:source) { create(:source, name: 'Dou', scraper: 'ApplyMate::Scraper::Dou') }

  let(:vacancy) do
    create(:vacancy, source:, url: CoideaDou::VACANCY_URL,
           title: 'UI/UX Designer', company_name: 'Coidea Agency')
  end

  let(:source_profile) do
    SourceProfile.create!(user:, source:, name: 'My DOU Profile',
                          auth_method: :session_id, session_id: 'test-session-id')
  end

  let(:user_profile) do
    UserProfile.create!(user:, name: 'Jane Doe',
                        cv: 'Senior UI/UX Designer with 5 years of experience.')
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

  # Canonical filled inputs for this vacancy (post-FillForm state).
  let(:filled_inputs) do
    [
      { 'name' => 'csrfmiddlewaretoken',
        'selector' => '[name="csrfmiddlewaretoken"]',
        'tag' => 'input', 'type' => 'hidden', 'form_index' => 0,
        'label' => '', 'placeholder' => '',
        'value' => 'oT3J2ws9iVPG6NQGwgzRo2N0CGJ428nE87IOzxDNiX5OP907lcKlRKTxNt9843KR' },
      { 'name' => 'descr',
        'selector' => '#reply_descr',
        'tag' => 'textarea', 'type' => 'textarea', 'form_index' => 1,
        'label' => 'Напишіть трохи про себе і про те, чому вакансія вам підходить',
        'placeholder' => '', 'value' => 'I am an experienced UI/UX designer.' },
      { 'name' => 'user_cv',
        'selector' => '#reply_file',
        'tag' => 'input', 'type' => 'file', 'form_index' => 2,
        'label' => 'Прикріпіть резюме', 'placeholder' => '', 'value' => '' }
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
