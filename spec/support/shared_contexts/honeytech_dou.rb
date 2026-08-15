# frozen_string_literal: true

module HoneytechDou
  FIXTURES_DIR    = Rails.root.join('spec/fixtures/files/dou/external/honeytech')
  VACANCY_URL     = 'https://jobs.dou.ua/companies/honeytech/vacancies/354709/'
  DOU_REDIRECT    = 'https://dou.ua/goto/vacancy/?id=354709'
  PEOPLEFORCE_URL = 'https://honeytech.peopleforce.io/careers/v/202646-ai-animator-motion-designer'
end

RSpec.shared_context 'honeytech dou' do
  # ── Fixtures ──────────────────────────────────────────────────────────────────
  let(:dou_vacancy_html)     { File.read(HoneytechDou::FIXTURES_DIR.join('dou_honeytech_vacancy_page.html')) }
  let(:honeytech_apply_html) { File.read(HoneytechDou::FIXTURES_DIR.join('honeytech_apply_page.html')) }

  # ── DB records ────────────────────────────────────────────────────────────────
  let(:user) do
    User.create!(email: 'dev@example.com', name: 'Jane Doe',
                 provider: 'google_oauth2', uid: 'uid-honeytech-test')
  end

  let(:source) { create(:source, name: 'Dou', scraper: 'ApplyMate::Scraper::Dou') }

  # Override in the consuming spec to pre-populate external_url on the vacancy.
  let(:vacancy_external_url) { nil }

  let(:vacancy) do
    create(:vacancy,
           source:,
           url:          HoneytechDou::VACANCY_URL,
           title:        'AI Animator / Motion Designer',
           company_name: 'Honeytech',
           external_url: vacancy_external_url)
  end

  let(:source_profile) do
    SourceProfile.create!(user:, source:, name: 'My DOU Profile',
                          auth_method: :session_id, session_id: 'test-session-id')
  end

  # UserProfile#name is the profile's LABEL, not a person's name — users name
  # profiles by specialisation. Deliberately different from User#name so a spec
  # asserting the applicant's name cannot pass by coincidence.
  let(:user_profile) do
    UserProfile.create!(user:, name: 'Motion Designer profile',
                        cv: 'Senior Motion Designer with 5 years of experience in AI animation.')
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

  # ── Browser double ────────────────────────────────────────────────────────────
  let(:browser) { instance_double(ApplyMate::Client::Browser) }

  # Live-session snapshot as PrepareSession stores it: raw fields with handles
  # plus the stamped submit button.
  let(:browser_snapshot) do
    {
      'fields' => raw_inputs,
      'submit' => { 'handle' => 'submit', 'text' => 'Застосувати',
                    'selector' => 'button[type="submit"].btn.btn-primary' }
    }
  end

  # Compact page digest as Browser#page_digest returns it for the PeopleForce
  # apply page — the AI-navigation (CheckFormPage) input.
  let(:browser_page_digest) do
    {
      'title'    => 'AI Animator / Motion Designer — HoneyTech',
      'url'      => HoneytechDou::PEOPLEFORCE_URL,
      'headings' => [ { 'level' => 'h1', 'text' => 'AI Animator / Motion Designer' } ],
      'forms'    => [
        { 'selector' => 'form', 'hidden' => false, 'submit_text' => 'Застосувати',
          'field_names' => [ 'career_application_form[full_name]', 'career_application_form[email]' ] }
      ],
      'fields_container' => nil,
      'buttons' => [ { 'selector' => 'form > button:nth-of-type(1)', 'text' => 'Застосувати', 'hidden' => false } ],
      'links'   => []
    }
  end

  # Post-submit observation: positive alert → deterministic success, no AI verify.
  let(:browser_observe_state) do
    {
      'url' => "#{HoneytechDou::PEOPLEFORCE_URL}/thank-you",
      'fields' => [], 'buttons' => [], 'errors' => [],
      'alerts' => [ 'Дякуємо за заявку!' ],
      'form_present' => false, 'captcha' => false, 'password_field' => false
    }
  end

  before do
    allow(ApplyMate::Client::Browser).to receive(:new).and_return(browser)

    allow(browser).to receive(:navigate_to)
    allow(browser).to receive(:current_url).and_return(HoneytechDou::PEOPLEFORCE_URL)
    allow(browser).to receive(:field_count).and_return(raw_inputs.size)
    allow(browser).to receive(:wait_for_fields).and_return(true)
    allow(browser).to receive(:iframe_sources).and_return([])
    allow(browser).to receive(:page_digest).and_return(browser_page_digest)
    allow(browser).to receive(:observe_state).and_return(browser_observe_state)
    allow(browser).to receive(:alive?).and_return(true)
    allow(browser).to receive(:click).and_return(true)
    allow(browser).to receive(:click_with_unique_path) { |selector| selector }
    allow(browser).to receive(:snapshot_fields).and_return(browser_snapshot)
    allow(browser).to receive(:fill_field)
    allow(browser).to receive(:fill_by_handle)
    # Real CDP input is preferred; the double reports typing as working and
    # clicking as impossible, so fallbacks stay exercised.
    allow(browser).to receive(:type_by_handle).and_return(true)
    allow(browser).to receive(:click_element_by_handle).and_return(false)
    allow(browser).to receive(:checkbox_checked?).and_return(false)
    allow(browser).to receive(:attach_file)
    allow(browser).to receive(:attach_file_by_handle).and_return(true)
    allow(browser).to receive(:click_by_handle).and_return(true)
    allow(browser).to receive(:attempt_recaptcha_refresh)
    allow(browser).to receive(:wait_for_idle)
    allow(browser).to receive(:body).and_return('<p>Дякуємо за заявку!</p>')
    allow(browser).to receive(:screenshot).and_return('')
    allow(browser).to receive(:quit)
  end

  # ── Misc stubs ────────────────────────────────────────────────────────────────
  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    allow_any_instance_of(Grover).to receive(:to_pdf).and_return('%PDF-1.4 fake-pdf-content')
  end

  # ── Canned Gemini responses ───────────────────────────────────────────────────
  let(:gemini_check_form_page) do
    gemini_json_response(
      '```json' "\n" \
      '{"has_form":true,"trigger_selector":null,"form_url":null,"form_selector":"form"}' "\n" \
      '```'
    )
  end

  let(:gemini_check_submit_result) do
    gemini_json_response(
      '```json' "\n" \
      '{"success":true,"reason":"Thank-you confirmation detected on the page."}' "\n" \
      '```'
    )
  end

  # AI maps only the ambiguous fields (full_name is type=text, cover_letter is a
  # textarea); email and resume resolve deterministically by input type.
  let(:gemini_map_fields) do
    mapping = {
      fingerprint_of(raw_inputs[0]) => 'full_name',
      fingerprint_of(raw_inputs[2]) => 'cover_letter'
    }
    gemini_json_response("```json\n#{mapping.to_json}\n```")
  end

  # The generation batch contains only the cover letter — contact fields come
  # from profile defaults, never from the AI.
  let(:gemini_fill_form) do
    answers = {
      fingerprint_of(raw_inputs[2]) =>
        'I am an experienced motion designer passionate about AI-driven animation.'
    }
    gemini_json_response("```json\n#{answers.to_json}\n```")
  end

  def fingerprint_of(input)
    Apply::FieldFingerprint.call(input)
  end

  # Canonical set of PeopleForce fields filled by AI for this vacancy.
  let(:filled_inputs) do
    [
      { 'name' => 'career_application_form[full_name]',
        'selector' => '[name="career_application_form[full_name]"]',
        'tag' => 'input', 'type' => 'text', 'form_index' => 0, 'handle' => 0,
        'label' => "Повне ім'я", 'placeholder' => '', 'value' => 'Jane Doe' },
      { 'name' => 'career_application_form[email]',
        'selector' => '[name="career_application_form[email]"]',
        'tag' => 'input', 'type' => 'email', 'form_index' => 1, 'handle' => 1,
        'label' => 'Електронна пошта', 'placeholder' => '', 'value' => 'dev@example.com' },
      { 'name' => 'career_application_form[cover_letter]',
        'selector' => '[name="career_application_form[cover_letter]"]',
        'tag' => 'textarea', 'type' => 'textarea', 'form_index' => 2, 'handle' => 2,
        'label' => 'Супровідний лист', 'placeholder' => '', 'value' =>
          'I am an experienced motion designer passionate about AI-driven animation.' },
      { 'name' => 'career_application_form[resume]',
        'selector' => '[name="career_application_form[resume]"]',
        'tag' => 'input', 'type' => 'file', 'form_index' => 4, 'handle' => 4,
        'label' => 'Резюме', 'placeholder' => '', 'value' => '' }
    ]
  end

  # Same fields as filled_inputs but with blank values — the state before AI filling.
  let(:raw_inputs) { filled_inputs.map { |i| i.merge('value' => '') } }

  # ── Helper ────────────────────────────────────────────────────────────────────
  def gemini_json_response(text)
    {
      status:  200,
      body:    { candidates: [ { content: { parts: [ { text: } ] } } ] }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    }
  end
end
