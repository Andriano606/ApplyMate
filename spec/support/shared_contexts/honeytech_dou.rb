# frozen_string_literal: true

module HoneytechDou
  FIXTURES_DIR    = Rails.root.join('spec/fixtures/files/dou/external/honeytech')
  VACANCY_URL     = 'https://jobs.dou.ua/companies/honeytech/vacancies/354709/'
  DOU_REDIRECT    = 'https://dou.ua/goto/vacancy/?id=354709'
  PEOPLEFORCE_URL = 'https://honeytech.peopleforce.io/careers/v/202646-ai-animator-motion-designer'
  # The PeopleForce form in the scripted page (peopleforce_form_html / peopleforce_form_snapshot).
  PEOPLEFORCE_FORM = 'body > main > form'
  PEOPLEFORCE_SUBMIT = "#{PEOPLEFORCE_FORM} > button".freeze
  PEOPLEFORCE_THANKS = 'Дякуємо за вашу заявку! Ми зв\'яжемося з вами найближчим часом.'
end

# A DOU external apply to HoneyTech's PeopleForce posting: a platform no adapter knows, so the engine runs it as
# `generic` and the AI Navigator reaches the form (design §6). Shared by the handler / job specs (FakeSession, the
# scripted PeopleForce page below) and the :browser e2e specs (which re-stub Session.open with the real browser).
#
# The Gemini stub is a ROUTER (stub_gemini_router): it reads every prompt and answers by its kind, with refs PARSED
# from the Navigate prompt text, never hard-coded, so the AI sees exactly what production would show it. Each call is
# recorded in gemini_prompts as [kind, prompt text]; kinds: :navigate, :answers, :cv, :verify.
RSpec.shared_context 'honeytech dou' do
  # ── Fixtures ──────────────────────────────────────────────────────────────────
  let(:dou_vacancy_html)     { File.read(HoneytechDou::FIXTURES_DIR.join('dou_honeytech_vacancy_page.html')) }
  let(:honeytech_apply_html) { File.read(HoneytechDou::FIXTURES_DIR.join('honeytech_apply_page.html')) }

  # ── DB records ────────────────────────────────────────────────────────────────
  let(:user_email) { unique_email('dev') }
  let(:user_phone) { unique_phone }

  let(:user) do
    User.create!(email: user_email, name: 'Jane Doe',
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

  # Facts already extracted for this CV, so Stage::AnswerFields makes no extraction call (the AI calls of the handler
  # specs stay the routed ones; the inline extraction is covered in answer_fields_spec.rb).
  let(:user_profile) do
    cv = 'Senior Motion Designer with 5 years of experience in AI animation.'
    UserProfile.create!(user:, name: 'Jane Doe', cv:, facts_cv_digest: Digest::SHA256.hexdigest(cv))
  end

  let(:ai_integration) do
    AiIntegration.create!(user:, provider: 'gemini',
                          model: 'gemini-2.5-flash', api_key: 'test-api-key')
  end

  # queued (the default state), so engine_context / the Runner can start it.
  let(:apply) do
    Apply.create!(user:, vacancy:, source_profile:, user_profile:, ai_integration:)
  end

  # ── The scripted PeopleForce page (spec/support/fake_session.rb, spec/support/snapshot_builder.rb) ─────────────
  # The application form as probe/snapshot.js reports it (the labels of honeytech_apply_page.html): f0:e0..e6 the
  # controls (the cover letter is PeopleForce's Froala contenteditable div), f0:e7 the "Застосувати" submit button.
  let(:peopleforce_form_snapshot) do
    form = HoneytechDou::PEOPLEFORCE_FORM
    control = ->(index, **options) { { css: "#{form} > *:nth-child(#{index})", regions: [ form ], required: true, **options } }
    build_snapshot(frames: [ { url: HoneytechDou::PEOPLEFORCE_URL, outline: [ 'AI Animator / Motion Designer' ] } ], elements: [
      snapshot_element(name: "Повне ім'я", id: 'career_application_form_full_name', **control.call(1)),
      snapshot_element(name: 'Електронна пошта', id: 'career_application_form_email', **control.call(2)),
      snapshot_element(name: 'Номер телефону', type: 'tel', **control.call(3)),
      snapshot_element(name: 'Супровідний лист', tag: 'div', **control.call(4, required: false)),
      snapshot_element(role: nil, name: 'Резюме', type: 'file', id: 'career_application_form_resume', **control.call(5)),
      snapshot_element(name: "Ім'я користувача Telegram", **control.call(6)),
      snapshot_element(name: 'Посилання', **control.call(7)),
      snapshot_element(role: 'button', name: 'Застосувати', type: 'submit', submit_like: true,
                       css: HoneytechDou::PEOPLEFORCE_SUBMIT, regions: [ form ])
    ])
  end

  let(:peopleforce_form_html) do
    <<~HTML
      <html><body><main><form id="new_career_application_form">
        <input type="text"><input type="text"><input type="tel"><div contenteditable="true"></div>
        <input type="file"><input type="text"><input type="text"><button type="submit">Застосувати</button>
      </form></main></body></html>
    HTML
  end

  # What PeopleForce shows after the submit: the form is replaced by the thank-you alert.
  let(:peopleforce_thanks_snapshot) { build_snapshot(frames: [ { url: HoneytechDou::PEOPLEFORCE_URL } ]) }
  let(:peopleforce_thanks_html) do
    "<html><body><main><div class=\"alert\">#{HoneytechDou::PEOPLEFORCE_THANKS}</div></main></body></html>"
  end

  # One scripted tab for both leases (the survey and the submit scope): it starts blank like a fresh lease, the
  # landing goto shows the PeopleForce form, a click on "Застосувати" shows the thank-you.
  let(:session) do
    FakeSession.new(html: '', final_url: 'about:blank').tap do |fake|
      fake.on(:goto) do
        fake.show(peopleforce_form_snapshot, url: HoneytechDou::PEOPLEFORCE_URL, html: peopleforce_form_html)
      end
      fake.on(:click) do |target|
        next unless target.strategies.any? { |strategy| strategy['css'] == HoneytechDou::PEOPLEFORCE_SUBMIT }

        fake.show(peopleforce_thanks_snapshot, html: peopleforce_thanks_html)
      end
    end
  end

  before { stub_browser_session(session) }

  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    allow(VacancyCv::TurboHandler::Index).to receive(:broadcast)
    allow(VacancyCv::TurboHandler::Index).to receive(:broadcast_row)
    allow(VacancyQuestion::TurboHandler::Index).to receive(:broadcast)
    allow_any_instance_of(Grover).to receive(:to_pdf).and_return('%PDF-1.4 fake-pdf-content')
  end

  # DetectPlatform's redirect walk (Handler::Dou runs it for every external apply): dou.ua/goto -> 302 -> the
  # PeopleForce page, which no adapter knows (generic, no probable platform), so the Navigator reaches its form.
  # Hosts resolve through FixtureSite.resolution (no DNS); ImpersonateHttp shells out to curl, so it is stubbed at
  # the client level like the vacancy page.
  def stub_honeytech_redirect_walk
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
      .with(HoneytechDou::DOU_REDIRECT, hash_including(follow_redirects: false))
      .and_return(ApplyMate::Client::Response.new('', { 'location' => HoneytechDou::PEOPLEFORCE_URL }, 302, nil))
    allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
      .with(HoneytechDou::PEOPLEFORCE_URL, hash_including(follow_redirects: false))
      .and_return(ApplyMate::Client::Response.new(honeytech_apply_html, {}, 200, HoneytechDou::PEOPLEFORCE_URL))
  end

  # ── The Gemini router ─────────────────────────────────────────────────────────
  let(:gemini_prompts) { [] }
  let(:cover_letter) { 'I animate characters with AI tools and would love to join HoneyTech.' }
  # AnswerFields answers by label (a label not listed is answered null). The quote the verify answer cites must be
  # in the page text after the submit.
  let(:answers_by_label) do
    { "Повне ім'я" => 'Jane Doe', 'Електронна пошта' => user_email, 'Номер телефону' => user_phone,
      'Супровідний лист' => cover_letter, "Ім'я користувача Telegram" => '@janedoe',
      'Посилання' => 'https://github.com/janedoe' }
  end
  let(:verify_quote) { 'Дякуємо за вашу заявку!' }

  # Every Gemini API call is answered by gemini_route and recorded in gemini_prompts.
  def stub_gemini_router
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return do |request|
      body = JSON.parse(request.body)
      parts = [ body.dig('system_instruction', 'parts'), *body['contents'].map { |content| content['parts'] } ]
      text = parts.flatten.compact.pluck('text').join("\n")
      gemini_json_response(gemini_route(text))
    end
  end

  # The answer text for one prompt (also what a stubbed browser-backed client's `complete` returns).
  def gemini_route(text)
    kind, answer =
      if text.include?('GOAL') then [ :navigate, gemini_navigate(text) ]
      elsif text.include?('Form fields to answer') then [ :answers, gemini_answers(text) ]
      elsif text.include?('```html') then [ :cv, gemini_cv ]
      elsif text.include?('submission') then [ :verify, gemini_verify_ok ]
      else raise "unrouted prompt: #{text.first(200)}"
      end
    gemini_prompts << [ kind, text ]
    answer
  end

  def gemini_prompt_kinds
    gemini_prompts.map(&:first)
  end

  # A Navigate turn decided from the prompt: a frame listing >= 3 fillable controls -> form_reached with exactly those
  # refs (and its "Next" button as advance_ref); otherwise click the "Apply" tab, or wait while it is already selected
  # (the widget mounts the form a moment later).
  def gemini_navigate(prompt)
    fillable = prompt.scan(/\[(f\d+:e\d+)\][^\n]*<(?:empty|filled)>/).flatten.group_by { |ref| ref.split(':').first }
    frame, field_refs = fillable.find { |_frame, refs| refs.size >= 3 }
    if field_refs
      return gemini_navigate_form_reached(frame:, scope_ref: field_refs.first, field_refs:,
                                          advance_ref: prompt[/\[(#{frame}:e\d+)\] button "Next"/, 1])
    end

    tab, selected = prompt.match(/\[(f\d+:e\d+)\] tab "Apply"( selected)?/)&.captures
    raise "no form and no Apply tab in the prompt:\n#{prompt}" if tab.nil?

    selected ? gemini_navigate_wait : gemini_navigate_click(ref: tab)
  end

  def gemini_navigate_click(ref:)
    navigate_answer('continue', actions: [ { type: 'click', ref:, key: nil, index: nil, max_ms: nil } ])
  end

  def gemini_navigate_wait(max_ms: 2_000)
    navigate_answer('continue', actions: [ { type: 'wait', ref: nil, key: nil, index: nil, max_ms: } ])
  end

  def gemini_navigate_form_reached(scope_ref:, field_refs:, frame: scope_ref.split(':').first, submit_ref: nil, advance_ref: nil)
    navigate_answer('form_reached', form: { frame:, scope_ref:, field_refs:, submit_ref:, advance_ref: })
  end

  # Answers every "- id: ... label: ..." block of the AnswerFields prompt by its label (answers_by_label).
  def gemini_answers(prompt)
    answers = prompt.scan(/^- id: (\S+)\n  kind: \S+\n  label: (.*)$/).to_h do |id, label|
      [ id, { value: answers_by_label[label.strip], confidence: 0.95 } ]
    end
    "```json\n#{answers.to_json}\n```"
  end

  def gemini_cv
    "```html\n<html><body><h1>Jane Doe</h1><p>AI Animator / Motion Designer</p></body></html>\n```"
  end

  def gemini_verify_ok
    "```json\n#{{ submitted: true, confidence: 0.95, quote: verify_quote }.to_json}\n```"
  end

  def navigate_answer(status, actions: [], form: nil)
    "```json\n#{{ status:, reason: 'test router', actions:, form:, give_up_code: nil }.to_json}\n```"
  end
end
