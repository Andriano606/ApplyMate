---
name: test-apply-handler
description: Step-by-step guide for writing RSpec tests for an Apply::Handler on the apply engine (Handler::Dou external = engine stages, Navigator, widgets, wizards, claim/verify) and for its stages. Use when adding or updating a handler spec, an engine stage/operation spec, a :browser end-to-end spec on FixtureSite pages, the shared contexts (FakeSession + snapshot builder + Gemini router), or a read-only apply:smoke check.
---

# Writing Tests for an Apply Handler on the Engine

Every external apply runs the engine (`Apply::Handler::Base.engine!`, `.ai/docs/apply_engine.md`): DetectPlatform ->
FetchSchema -> `:survey` scope (ReachForm, DiscoverFields) -> AnswerFields -> CV -> ReviewGate -> AcquireHostSlot ->
`:submit` scope (ReachForm replay, DiscoverFields reconcile, FillFields, Submit, Verify). A known platform (Ashby) is
reached by its adapter, anything else stays `generic` and is reached by the AI Navigator. Only the internal DOU path
(`FetchInternalForm`, `Ai::FillForm`, `SendApply::Http`) and Djinni keep the pre-engine HTTP steps until phase 4.

Read first: `.ai/docs/rspec.md` ("FakeSession (browser steps)", "Browser specs (`:browser`)", the shared contexts),
`.ai/docs/apply_engine.md` ("Specs", "Navigator (Generic)", "Widgets", "Submit and Verify"), `.ai/docs/apply_handlers.md`.

## File layout

```
spec/
  support/
    shared_contexts/<company>_<source>.rb           # DB records, scripted FakeSession, Gemini router
    snapshot_builder.rb                             # build_snapshot / snapshot_element (production SnapshotAll)
    fake_session.rb                                 # FakeSession (same API as Session, contract-checked)
    fixture_site.rb                                 # FixtureSite: real pages for :browser specs
    fixture_site/pages/<platform or generic>/*.html # {{ORIGIN}} / {{ALT_ORIGIN}} placeholders, no real hosts
  fixtures/files/<source>/<apply_type>/<company>/   # saved real pages (vacancy page, employer form)
  concepts/apply/
    handler/<source>_spec.rb                        # routing + full engine run on FakeSession (no browserd)
    handler/<source>_<platform>_browser_spec.rb     # :browser end to end: real Session + FixtureSite
    job/apply_e2e_spec.rb                           # Job -> Handler -> Runner: idempotent re-run, zombie, job_id
    operation/stage/<stage>_spec.rb                 # one stage on FakeSession / engine_context
    operation/engine/<operation>_spec.rb            # Navigate, ExecuteAction, ClassifyAdvance, VerifySubmit, ...
    widget/<widget>_spec.rb                         # + a :browser example on fixture_site/pages/widgets.html
```

One spec file per class; several companies testing the same class are `context` blocks inside it.

## Step 1 — Real fixtures, then a scripted page

Save the real vacancy page and the employer's form page under `spec/fixtures/files/...` (DetectPlatform reads the
employer HTML over HTTP: signals, `already_applied`, http gates). The browser side is NOT the saved HTML: it is a
**snapshot** as `probe/snapshot.js` would report it, built with the production `SnapshotAll`:

```ruby
let(:form_snapshot) do
  form = 'body > main > form'
  control = ->(index, **options) { { css: "#{form} > *:nth-child(#{index})", regions: [ form ], required: true, **options } }
  build_snapshot(frames: [ { url: FORM_URL, outline: [ 'AI Animator / Motion Designer' ] } ], elements: [
    snapshot_element(name: 'Full name', **control.call(1)),
    snapshot_element(name: 'Email', type: 'email', **control.call(2)),
    snapshot_element(name: 'Cover letter', tag: 'div', **control.call(3, required: false)), # contenteditable
    snapshot_element(role: nil, name: 'Resume', type: 'file', **control.call(4)),
    snapshot_element(role: 'button', name: 'Apply', type: 'submit', submit_like: true, css: "#{form} > button", regions: [ form ])
  ])
end
```

Pass a `tag > tag:nth-child` chain as `css:` wherever the spec needs DOM ancestry: the Navigator derives the form root
from the claimed refs' css paths.

## Step 2 — The shared context

Constants go in a companion **module** (constants inside `RSpec.describe` / `shared_context` land on `Object`).
`spec/support/shared_contexts/honeytech_dou.rb` is the reference:

- **Records**: user, source, vacancy, source profile, a `UserProfile` with `facts_cv_digest` set (no inline facts
  extraction call), a Gemini `AiIntegration`, a `queued` apply.
- **Contacts**: `let(:user_email) { unique_email('dev') }`, `let(:user_phone) { unique_phone }`. Every test e-mail and
  phone is generated per use with `unique_email` / `unique_phone` (features: `<unique_email:NAME>` /
  `<unique_phone:NAME>`). Never a literal like `dev@example.com` and never the same literal twice.
- **Scripted session**: one `FakeSession` for both leases; it starts at `about:blank`, `on(:goto)` shows the form
  snapshot, a click on the submit target shows the thank-you snapshot:

```ruby
let(:session) do
  FakeSession.new(html: '', final_url: 'about:blank').tap do |fake|
    fake.on(:goto) { fake.show(form_snapshot, url: FORM_URL, html: form_html) }
    fake.on(:click) { |target| fake.show(thanks_snapshot, html: thanks_html) if submit?(target) }
  end
end
before { stub_browser_session(session) }
```

- **Redirect walk**: DetectPlatform follows `dou.ua/goto` hop by hop over `ImpersonateHttp` (curl, bypasses WebMock),
  so stub `ImpersonateHttp#get` with `hash_including(follow_redirects: false)` per hop and
  `ResolvePublicAddress.call` with `FixtureSite.resolution(url)` (`stub_honeytech_redirect_walk`).
- **Gemini router**: one WebMock stub that reads the prompt and answers by its kind (below).

## Step 3 — Stub the AI with a router, never a fixed sequence

The engine's call order depends on the page (how many Navigator turns, whether page 2 asks follow-up answers), so a
`to_return(a, b, c)` sequence is wrong. Route by prompt content and record each call:

```ruby
def stub_gemini_router
  stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return do |request|
    body = JSON.parse(request.body)
    parts = [ body.dig('system_instruction', 'parts'), *body['contents'].map { |content| content['parts'] } ]
    gemini_json_response(gemini_route(parts.flatten.compact.pluck('text').join("\n")))
  end
end

def gemini_route(text)
  kind, answer =
    if text.include?('GOAL') then [ :navigate, gemini_navigate(text) ]                  # Prompt::Navigate
    elsif text.include?('Form fields to answer') then [ :answers, gemini_answers(text) ] # Prompt::AnswerFields
    elsif text.include?('```html') then [ :cv, gemini_cv ]                               # Prompt::GenerateCv
    elsif text.include?('submission') then [ :verify, gemini_verify_ok ]                 # Prompt::VerifySubmit
    else raise "unrouted prompt: #{text.first(200)}"
    end
  gemini_prompts << [ kind, text ]
  answer
end
```

**Navigate turns are decided from the prompt text.** Parse the refs the prompt lists; never hard-code `f1:e2` (refs
change with the page, the frame order and every probe change):

```ruby
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
```

Building blocks (all return the answer text): `gemini_navigate_click(ref:)`, `gemini_navigate_wait(max_ms:)`,
`gemini_navigate_form_reached(scope_ref:, field_refs:, frame:, submit_ref:, advance_ref:)`, `gemini_answers(prompt)`
(answers every `- id: / kind: / label:` block from `answers_by_label`), `gemini_cv`, `gemini_verify_ok` (cites
`verify_quote`, which must be in the page text after the submit). Answers built from the context's
`user_email` / `user_phone`, so the POST body proves the read-back.

A browser-backed client (GeminiScraping) reuses the router instead of WebMock (no real Chrome):

```ruby
allow(ApplyMate::Ai::Client::GeminiScraping).to receive(:new).and_return(scraping_client)
allow(scraping_client).to receive(:complete) do |request|
  prompt = [ request.system, *request.messages.map { |message| message[:content] } ].compact.join("\n\n")
  ApplyMate::Ai::Response.new(text: gemini_route(prompt), usage: ApplyMate::Ai::Usage::UNKNOWN)
end
```

Termination specs drive the router into a corner on purpose: the same click every turn -> `stuck`; a ref that is not
in the prompt -> rejected by `ExecuteAction` without touching the session (`session.calls_of(:click)` empty);
`continue` forever -> `budget_exhausted` after `Navigate::MAX_TURNS`; `CallAi` caps -> `ai_budget_exhausted`.

## Step 4 — The handler spec (no browserd)

`spec/concepts/apply/handler/<source>_spec.rb`, `include_context '<company> <source>'`, stub the vacancy page on
`ImpersonateHttp`, the redirect walk and the router. Assert:

- routing: `platform` (`generic` for an unknown site), `platform_match`, `entry_url`, `form_url`, `detect`'s hops;
- the step keys of the attempt, in order (`apply_steps.chronological.map(&:key)`), e.g. for an external DOU apply
  `check_applyable fetch_apply_type detect schema navigate:survey discover:survey answer generate_cv review throttle
  navigate:replay:submit discover:submit fill:submit submit:submit verify:submit`; the internal path's keys
  separately ("step conditions": no two active steps share a key, exactly one `generate_cv`);
- leases: `session.open_options.map { |o| o[:humanize] } == [false, true]` (survey, submit);
- `navigation`: op hashes only (`goto` with `url_template: '{landing_url}'`, the clicks, a terminal `wait_for`),
  never a literal URL, never `fill`;
- fields (`apply.field_list`: label, `widget`, `target.frame_path`) and `answers` (contain `user_email`/`user_phone`);
- **the claim before the irreversible action**:

```ruby
claimed_at_click = []
session.on(:click) { |target| claimed_at_click << Apply.find(apply.id).submit_claimed_at if submit?(target) }
run_handler
expect(claimed_at_click).to contain_exactly(be_present)
```

- the final state (`completed`, `submitted_via: 'engine'`), the AI counters (`ai_calls`, `ai_calls_total`) and
  `gemini_prompt_kinds`;
- the halts that matter for the source: Google Forms / captcha -> `needs_human` before any lease, `already_applied`,
  `review_policy: :unknown_platforms` -> `needs_review` (`unknown_platform`) with no submit lease.

Single stages: `run_engine_step(apply, Stage::X, **options)` or `Stage::X.call(ctx: engine_context(apply), ...)`.
`engine_context(apply)` is a real `StartContext`; `rotate_run_token!(apply)` simulates a newer run (zombie writes
nothing).

## Step 5 — The `:browser` end to end on FixtureSite

`spec/concepts/apply/handler/<source>_<platform>_browser_spec.rb`, `:browser, type: :job`, mirrors
`dou_ashby_browser_spec.rb` / `dou_generic_browser_spec.rb`. It runs the PRODUCTION path: `Session` + Playwright driver
against browserd-test and real pages; only the DOU HTTP and Gemini are stubbed.

1. **Pages**: add them under `spec/support/fixture_site/pages/<name>/` with `{{ORIGIN}}` / `{{ALT_ORIGIN}}` (a second
   origin for cross-origin iframes). For an unknown site put NO `data-*` platform markers anywhere. A submit posts to
   a FixtureSite route recorded through `FixtureSite.record_submission(op, request, answer)` (e.g.
   `POST /generic/submit` -> `{ op: 'generic', body: }`, answers `{"ok":true}`).
2. **DOU chain** on `ImpersonateHttp` (`allow(http).to receive(:get) { |url, **| pages.fetch(url) }`): vacancy page,
   `DOU_REDIRECT` -> 302 -> `FixtureSite.url('/generic/careers.html')`, the careers HTML with placeholders replaced;
   `allow(http).to receive(:post) { raise ... }`.
3. **Real Session, counted leases**: `allow(Session).to receive(:open).and_wrap_original { |original, **o, &b| opens << o; original.call(**o, &b) }`.
4. **Claim before the POST**: `FixtureSite.on_submit { claimed_at_post << Apply.find(apply.id).submit_claimed_at }`,
   then `expect(claimed_at_post).to contain_exactly(be_present)` and `FixtureSite.submissions.sole[:op]`.
5. **Read-back proved by the site**: parse `FixtureSite.submissions.sole[:body]` and expect every answered value
   (`user_email`, `user_phone`, the select's label, the contenteditable text, the file name, consent `true`).
6. **Idempotence**: a second `run_job` changes neither the step rows nor `FixtureSite.submissions.size`.
7. **Resume**: `review_policy: :unknown_platforms` -> `needs_review`; `ApproveReview.call(params: { id: apply.hashid },
   current_user: user)` -> the stored navigation replays through `Recipe::Interpret` (assert no `:navigate` prompt after
   the survey) and submits once.

Run with `BROWSERD_URL=http://localhost:9310 bundle exec rspec --tag browser` (the tag is excluded when `BROWSERD_URL`
is blank). A widget driver gets its own `:browser` example on `fixture_site/pages/widgets.html` with read-back.

## Step 6 — Read-only live smoke (optional, never in CI)

`bin/rails 'apply:smoke[<throwaway apply hashid>,<entry url>]'` with the dev `BROWSERD_URL` / `BROWSERD_TOKEN` runs
`Apply::Operation::SmokeSurvey`: detection, schema, one lease that reaches the form (Navigator included for a generic
site) and lists the field inventory. It never fills, never claims, never submits, and ends the apply `cancelled`.
Use a throwaway apply and an AI integration you are allowed to spend on. Never submit a real application or POST to a
real ATS from a spec or a console.

## Checklist

- [ ] Real vacancy / employer pages saved under `spec/fixtures/files/<source>/<apply_type>/<company>/`
- [ ] Shared context: constants in a companion module, scripted `FakeSession` built with `build_snapshot`, the Gemini
      router (`stub_gemini_router`), `user_email` / `user_phone` from `unique_email` / `unique_phone`
- [ ] Navigate answers use refs parsed from the prompt; no hard-coded ref anywhere
- [ ] Handler spec: platform, step keys in order, two leases (humanize false/true), navigation without literal URL or
      `fill`, fields + widgets, claim before the submit click, final state, AI counters
- [ ] Termination specs where the Navigator / recovery / wizard loop is touched: stuck, rejected ref, budget exhausted
- [ ] `:browser` e2e on FixtureSite pages: one recorded POST, the claim before it (`FixtureSite.on_submit`), read-back
      proved by the POST body, idempotent re-run
- [ ] `grep -rn "@example.com" spec/concepts/apply spec/support/shared_contexts` shows no literal address
- [ ] `.ai/docs/rspec.md` / `.ai/docs/apply_engine.md` "Specs" updated when a helper, context or fixture page changes
