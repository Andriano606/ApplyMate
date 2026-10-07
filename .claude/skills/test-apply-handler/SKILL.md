---
name: test-apply-handler
description: Step-by-step guide for writing RSpec tests for an Apply::Handler and its individual pipeline operations. Use when adding or updating specs for a job-board handler (DOU, Djinni, etc.) and its steps (FetchExternalForm, FillForm, SendApply::Browser, etc.).
---

# Writing Tests for an Apply Handler and Its Operations

Each handler has a full-pipeline integration spec plus one focused spec per significant operation step. All of them share a common context defined in `spec/support/shared_contexts/`.

## File layout

```
spec/
  support/shared_contexts/<source>_<company>.rb   # shared fixtures + stubs
  fixtures/files/<source>/<apply_type>/<company>/
    <source>_<company>_vacancy_page.html           # job listing page
    <company>_apply_page.html                      # employer form page
  concepts/apply/
    handler/<source>/<company>_spec.rb             # full pipeline
    operation/ai/fetch_external_form/<company>_spec.rb
    operation/ai/fill_form/<company>_spec.rb
    operation/send_apply/browser/<company>_spec.rb
```

## Step 1 — Acquire real HTML fixtures

Save the actual scraped pages — not hand-crafted stubs. Real pages expose real field names, CSS selectors, and selector edge-cases (Tailwind variant classes, bracket-style IDs, etc.).

```
spec/fixtures/files/dou/external/honeytech/
  dou_honeytech_vacancy_page.html   # curl/browser-save the DOU vacancy listing
  honeytech_apply_page.html         # curl/browser-save the employer apply page
```

## Step 2 — Create the shared context

One file per `(source, company)` pair. Keep URL constants in a companion **module** (not inside the `shared_context` block) — constants defined inside `RSpec.describe` blocks are hoisted to `Object` and clash across files.

````ruby
# spec/support/shared_contexts/honeytech_dou.rb
module HoneytechDou
  FIXTURES_DIR    = Rails.root.join('spec/fixtures/files/dou/external/honeytech')
  VACANCY_URL     = 'https://jobs.dou.ua/companies/honeytech/vacancies/354709/'
  DOU_REDIRECT    = 'https://dou.ua/goto/vacancy/?id=354709'
  PEOPLEFORCE_URL = 'https://honeytech.peopleforce.io/careers/v/202646-ai-animator-motion-designer'
end

RSpec.shared_context 'honeytech dou' do
  # ── Fixtures ──────────────────────────────────────────────────────────────
  let(:dou_vacancy_html)     { File.read(HoneytechDou::FIXTURES_DIR.join('dou_honeytech_vacancy_page.html')) }
  let(:honeytech_apply_html) { File.read(HoneytechDou::FIXTURES_DIR.join('honeytech_apply_page.html')) }

  # ── DB records ────────────────────────────────────────────────────────────
  let(:user) do
    User.create!(email: 'dev@example.com', name: 'Jane Doe',
                 provider: 'google_oauth2', uid: 'uid-test')
  end
  let(:source)       { create(:source, name: 'Dou', scraper: 'ApplyMate::Scraper::Dou') }
  let(:vacancy_external_url) { nil }   # override per spec to pre-set external_url
  let(:vacancy)      { create(:vacancy, source:, url: HoneytechDou::VACANCY_URL, external_url: vacancy_external_url) }
  let(:source_profile) { SourceProfile.create!(user:, source:, auth_method: :session_id, session_id: 'sid') }
  let(:user_profile)   { UserProfile.create!(user:, name: 'Jane Doe', cv: 'Senior designer…') }
  let(:ai_integration) { AiIntegration.create!(user:, provider: 'gemini', model: 'gemini-2.5-flash', api_key: 'key') }
  let(:apply) do
    Apply.create!(user:, vacancy:, source_profile:, user_profile:, ai_integration:)  # queued
  end

  # ── Browser session (spec/support/fake_session.rb, see .ai/docs/rspec.md "FakeSession") ──
  # One scripted page for both browser steps; Session.open yields it and records its kwargs.
  # Override `let(:session)` per context: FakeSession.new(..., missing: [css], read_values: { css => value }).
  let(:session) { FakeSession.new(html: honeytech_apply_html, final_url: HoneytechDou::PEOPLEFORCE_URL) }

  before { stub_browser_session(session) }

  # ── Misc stubs ────────────────────────────────────────────────────────────
  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    allow(VacancyCv::TurboHandler::Index).to receive(:broadcast)
    allow(VacancyCv::TurboHandler::Index).to receive(:broadcast_row)
    allow(VacancyQuestion::TurboHandler::Index).to receive(:broadcast)
    allow_any_instance_of(Grover).to receive(:to_pdf).and_return('%PDF-1.4 fake')
  end

  # ── Canned Gemini responses ───────────────────────────────────────────────
  # Define one let per distinct AI call in the pipeline.
  # Shared between the handler spec (full sequence) and each operation spec (single call).
  let(:gemini_check_form_page) do
    gemini_json_response('```json' "\n" '{"has_form":true,"trigger_selector":null,"form_url":null,"form_selector":"form"}' "\n" '```')
  end
  let(:gemini_fill_form) do
    gemini_json_response('```json' "\n" '{"field[name]":"Jane Doe","field[email]":"dev@example.com"}' "\n" '```')
  end
  let(:gemini_check_submit_result) do
    gemini_json_response('```json' "\n" '{"success":true,"reason":"Thank-you page detected."}' "\n" '```')
  end

  # Canonical filled inputs (after AI filling). Derive raw_inputs for pre-fill state.
  let(:filled_inputs) do
    [
      { 'name' => 'field[name]', 'selector' => '[name="field[name]"]',
        'tag' => 'input', 'type' => 'text', 'form_index' => 0, 'value' => 'Jane Doe' },
      { 'name' => 'field[resume]', 'selector' => '[name="field[resume]"]',
        'tag' => 'input', 'type' => 'file', 'form_index' => 1, 'value' => '' }
    ]
  end
  let(:raw_inputs) { filled_inputs.map { |i| i.merge('value' => '') } }
end
````

`spec/support/**/*.rb` is auto-required by `rails_helper.rb` — no explicit require needed. `gemini_json_response(text, usage: nil)` (and `ollama_chat_response`) come from `spec/support/ai_responses.rb`, included in every spec — do not redefine them in the shared context.

## Step 3 — Full-pipeline handler spec

Stubs the DOU vacancy page (HTTP) and all Gemini calls in pipeline order. Uses shared `let`s for canned responses.

```ruby
# spec/concepts/apply/handler/dou/honeytech_spec.rb
require 'rails_helper'

RSpec.describe Apply::Handler::Dou do
  include_context 'honeytech dou'

  before do
    stub_request(:get, HoneytechDou::VACANCY_URL)
      .to_return(status: 200, body: dou_vacancy_html,
                 headers: { 'Content-Type' => 'text/html; charset=utf-8' })

    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(gemini_check_form_page, gemini_fill_form, gemini_generate_cv, gemini_check_submit_result)
  end

  describe '#call' do
    subject(:run_handler) { described_class.new(apply:).call }

    it 'detects the apply type'              { run_handler; expect(apply.reload.apply_type).to eq('external') }
    it 'stores the external URL on vacancy'  { run_handler; expect(vacancy.reload.external_url).to eq(HoneytechDou::DOU_REDIRECT) }
    it 'populates form fields'               { run_handler; expect(apply.reload.inputs.map { |i| i['name'] }).to include('field[name]') }
    it 'stores AI-filled values'             { run_handler; expect(apply.reload.filled_inputs).to include(hash_including('name' => 'field[name]', 'value' => 'Jane Doe')) }
    it 'attaches a generated CV'             { run_handler; expect(apply.reload.cv).to be_attached }
    it 'completes without error'             { run_handler; expect(apply.reload).to be_completed; expect(apply.failure).to be_nil }
    it 'navigates to the external URL'       { run_handler; expect(session.calls).to include([ :goto, HoneytechDou::DOU_REDIRECT ]) }
    it 'submits in a humanized session'      { run_handler; expect(session.open_options.last).to include(humanize: true) }
    it 'clicks submit once'                  { run_handler; expect(session.calls_of(:click).sole.first.strategies.first).to include('has_text' => a_string_including('Apply')) }
  end
end
```

## Step 4 — FetchExternalForm spec

Override `vacancy_external_url` so the vacancy already has `external_url` set (this operation starts after `FetchApplyType` resolves it). Stub only the one Gemini call it makes.

```ruby
# spec/concepts/apply/operation/ai/fetch_external_form/honeytech_spec.rb
require 'rails_helper'

RSpec.describe Apply::Operation::Ai::FetchExternalForm do
  include_context 'honeytech dou'

  let(:vacancy_external_url) { HoneytechDou::DOU_REDIRECT }

  before do
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(gemini_check_form_page)
  end

  describe '#call' do
    subject(:run_operation) { described_class.call(ctx: engine_context(apply)) }

    it 'renders the page in a session'     { run_operation; expect(session.calls).to include([ :goto, HoneytechDou::DOU_REDIRECT ]) }
    it 'opens it without humanize'         { run_operation; expect(session.open_options.sole).to include(humanize: false) }
    it 'populates inputs'                  { run_operation; expect(apply.reload.inputs.map { |i| i['name'] }).to include('field[name]') }
    it 'resolves the form action URL'      { run_operation; expect(apply.reload.action).to start_with('https://') }
    it 'stores the http method'            { run_operation; expect(apply.reload.http_method).to eq('post') }
    it 'stores a submit selector'          { run_operation; expect(apply.reload.submit_selector).to start_with('button[type="submit"]') }
    it 'preserves external_url'            { run_operation; expect(apply.reload.external_url).to eq(HoneytechDou::DOU_REDIRECT) }
  end
end
```

## Step 5 — FillForm spec

Pre-populate `apply.inputs` with `raw_inputs` (the pre-AI state). Pass `prompt_class:` and `schema_class:` — these come from `add_step` options in the handler and must be given explicitly when calling the operation directly.

```ruby
# spec/concepts/apply/operation/ai/fill_form/honeytech_spec.rb
require 'rails_helper'

RSpec.describe Apply::Operation::Ai::FillForm do
  include_context 'honeytech dou'

  before do
    apply.update!(inputs: raw_inputs)
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(gemini_fill_form)
  end

  describe '#call' do
    subject(:run_operation) do
      described_class.call(ctx: engine_context(apply),
                           prompt_class: Apply::Ai::Prompt::FillForm,
                           schema_class: Apply::Ai::ResponseSchema::FillForm)
    end

    it 'merges AI values into filled_inputs' do
      run_operation
      expect(apply.reload.filled_inputs).to include(hash_including('name' => 'field[name]', 'value' => 'Jane Doe'))
    end

    it 'leaves file inputs unchanged' do
      run_operation
      resume = apply.reload.filled_inputs.find { |i| i['type'] == 'file' }
      expect(resume['value']).to eq('')
    end

    it 'preserves input metadata (selector, tag, form_index)' do
      run_operation
      input = apply.reload.filled_inputs.find { |i| i['name'] == 'field[name]' }
      expect(input).to include('selector' => '[name="field[name]"]', 'tag' => 'input', 'form_index' => 0)
    end

    it 'stores no failure' { run_operation; expect(apply.reload.failure).to be_nil }
  end
end
```

## Step 6 — SendApply::Browser spec

Pre-populate `apply` with the full post-FillForm state: `external_url`, `submit_selector`, `submit_text`, `filled_inputs`, and an attached CV. Stub only `CheckSubmitResult`.

```ruby
# spec/concepts/apply/operation/send_apply/browser/honeytech_spec.rb
require 'rails_helper'

RSpec.describe Apply::Operation::SendApply::Browser do
  include_context 'honeytech dou'

  before do
    apply.update!(external_url: HoneytechDou::DOU_REDIRECT,
                  submit_selector: 'button[type="submit"].btn',
                  submit_text: 'Apply',
                  filled_inputs:)
    apply.cv.attach(io: StringIO.new('%PDF-1.4 fake'), filename: 'CV.pdf',
                    content_type: 'application/pdf')
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(gemini_check_submit_result)
  end

  describe '#call' do
    subject(:run_operation) { described_class.call(ctx: engine_context(apply)) }

    let(:submit_target) do
      ApplyMate::Client::Browser::Target.new(
        frame_path: [], root: nil, readonly: false,
        strategies: [ { 'css' => 'button[type="submit"].btn', 'has_text' => 'Apply' }, { 'css' => 'button[type="submit"].btn' } ]
      )
    end

    it 'navigates to external URL'     { run_operation; expect(session.calls).to include([ :goto, HoneytechDou::DOU_REDIRECT ]) }
    it 'fills text inputs'             { run_operation; expect(session.calls_of(:fill).map(&:last)).to include('Jane Doe') }
    it 'never fills file inputs'       { run_operation; expect(session.calls_of(:fill).map { |t, _| t.strategies.first['css'] }).not_to include(a_string_including('resume')) }
    it 'uploads the CV'                { run_operation; expect(session.calls_of(:upload).sole.last).to end_with('.pdf') }
    it 'clicks submit button'          { run_operation; expect(session.calls_of(:click).map(&:first)).to eq([ submit_target ]) }
    it 'leaves the lifecycle to the Runner' { run_operation; expect(apply.reload.submit_claimed_at).to be_present }

    it 'claims before the click' do
      claimed = nil
      session.on(:click) { claimed = Apply.find(apply.id).submit_claimed_at }
      run_operation
      expect(claimed).to be_present
    end

    context 'when the submit button is missing' do
      let(:session) { FakeSession.new(html: honeytech_apply_html, final_url: HoneytechDou::PEOPLEFORCE_URL, missing: [ 'button[type="submit"].btn' ]) }

      it 'fails before the claim' do
        expect(run_engine_step(apply, described_class)).to be_failed
        expect(apply.submit_claimed_at).to be_nil
      end
    end

    context 'when trigger_selector is set' do
      before { apply.update!(trigger_selector: '#open-form') }

      it 'clicks trigger before submit' do
        run_operation
        expect(session.calls_of(:click).map(&:first))
          .to eq([ ApplyMate::Client::Browser::Target.css('#open-form'), submit_target ])
      end
    end
  end
end
```

## Checklist

- [ ] Real HTML fixtures saved under `spec/fixtures/files/<source>/<apply_type>/<company>/`
- [ ] Shared context at `spec/support/shared_contexts/<source>_<company>.rb` — constants in companion module, one `let` per canned Gemini response
- [ ] Handler spec — stubs DOU vacancy page + all Gemini calls in pipeline order
- [ ] `FetchExternalForm` spec — overrides `vacancy_external_url`, stubs 1 Gemini call
- [ ] `FillForm` spec — sets `apply.inputs = raw_inputs`, passes `prompt_class:` and `schema_class:`
- [ ] `SendApply::Browser` spec — pre-populates full post-FillForm state, attaches CV, stubs `CheckSubmitResult`
