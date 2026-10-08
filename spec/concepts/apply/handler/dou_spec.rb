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
      stub_honeytech_redirect_walk

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
                         'value' => user_email)
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
          %w[check_applyable fetch_apply_type detect fetch_form fill_form generate_cv submit].map { |key| [ key, 'succeeded', 1 ] }
        )
      end

      it 'detects PeopleForce as an unknown platform first, then keeps the legacy external path' do
        run_handler
        reloaded = apply.reload

        expect(reloaded).to have_attributes(platform: 'generic', entry_url: HoneytechDou::DOU_REDIRECT, apply_key: nil)
        expect(reloaded.platform_match).to include('key' => 'generic', 'probable' => nil)
        detect = reloaded.apply_steps.find_by!(key: 'detect')
        expect(detect.result.dig('evidence', 'hops')).to eq([ HoneytechDou::DOU_REDIRECT, HoneytechDou::PEOPLEFORCE_URL ])
        expect(detect.position).to be < reloaded.apply_steps.find_by!(key: 'fetch_form').position
      end

      it 'runs no engine stage after detection for an unknown platform (no schema read, no survey lease)' do
        run_handler

        engine_keys = %w[schema navigate:survey discover:survey answer review throttle navigate:replay:submit
                         discover:submit fill:submit submit:submit verify:submit]
        expect(apply.apply_steps.where(key: engine_keys)).to be_empty
        expect(session.open_options.size).to eq(2) # FetchExternalForm + SendApply::Browser
      end

      it 'renders the form, then submits in a separate humanized session at the DOU redirect URL' do
        run_handler
        expect(session.open_options.map { |options| options[:humanize] }).to eq([ false, true ])
        expect(session.calls_of(:goto)).to eq([ [ HoneytechDou::DOU_REDIRECT ], [ HoneytechDou::DOU_REDIRECT ] ])
      end

      it 'clicks the submit button with the Ukrainian label, once' do
        run_handler
        target = session.calls_of(:click).sole.first
        expect(target.strategies.first).to match('css' => a_string_starting_with('button[type="submit"]'),
                                                 'has_text' => a_string_including('Застосувати'))
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
          expect(session.open_options).to be_empty
        end
      end
    end
  end

  context 'DOU external apply to a platform the registry knows (Ashby at the HTTP level)' do
    include_context 'honeytech dou'

    let(:jid) { '20587adf-cf02-473e-8a80-7b009711a2cf' }
    let(:ashby_job) { "https://jobs.ashbyhq.com/preply/#{jid}" }
    let(:posting) { ApplyMate::Client::Response.new(file_fixture('apply_engine/ashby/api_job_posting.json').read, {}, 200, nil) }

    before do
      allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
      pages = {
        HoneytechDou::VACANCY_URL => ApplyMate::Client::Response.new(dou_vacancy_html, {}, 200, HoneytechDou::VACANCY_URL),
        HoneytechDou::DOU_REDIRECT => ApplyMate::Client::Response.new('', { 'location' => ashby_job }, 302, nil),
        ashby_job => ApplyMate::Client::Response.new('<html><body><div id="root"></div></body></html>', {}, 200, nil)
      }
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get) { |_http, url, **| pages.fetch(url) }
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:post).and_return(posting)
      # Gemini in call order: AnswerFields, GenerateCv.
      stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(
        gemini_json_response(fixture_ashby_answers_json(email: user_email, phone: user_phone)),
        gemini_json_response("```html\n<html><body><h1>Jane Doe</h1></body></html>\n```")
      )
      # The review stops the run before the submit scope: the routing is visible without a browser.
      user.update!(review_policy: :always)
    end

    it 'runs the engine stages (no survey: canonical URL + schema) and never the legacy external steps' do
      described_class.new(apply:).call
      reloaded = apply.reload

      expect(reloaded).to have_attributes(state: 'needs_review', platform: 'ashby', apply_key: "ashby:preply:#{jid}",
                                          form_url: "#{ashby_job}/application")
      expect(reloaded.apply_steps.chronological.map(&:key))
        .to eq(%w[check_applyable fetch_apply_type detect schema answer generate_cv review])
      expect(reloaded.field_list.size).to eq(15)
      expect(reloaded.answers.keys).to include('ashby:_systemfield_email', 'ashby:6257e5b0-1d2a-4c55-9a51-3f0f2a6c1e01')
      expect(session.open_options).to be_empty
      expect(reloaded.inputs).to be_nil # Ai::FetchExternalForm never ran
    end
  end

  describe 'step conditions' do
    # apply_steps is unique on (apply_id, attempt, key): for every apply type and detection outcome the steps that
    # may run share no key, and the CV is generated by exactly one generate_cv step (the engine's or the legacy one).
    def active_keys(external:, known:, probable:)
      ctx = instance_double(Apply::Operation::Engine::Context,
                            apply: instance_double(Apply, external?: external, internal?: !external),
                            platform_known?: known, platform_reachable?: known || probable, survey_needed?: true)
      described_class.steps.select do |step|
        scope_condition = step.scope && described_class.scope_conditions[step.scope]
        [ step.condition, scope_condition ].compact.all? { |condition| condition.call(ctx) }
      end.map(&:key)
    end

    [ true, false ].product([ true, false ], [ true, false ]).each do |external, known, probable|
      it "never runs two steps with one key (external: #{external}, known: #{known}, probable: #{probable})" do
        keys = active_keys(external:, known:, probable:)

        expect(keys).to eq(keys.uniq)
        expect(keys.count('generate_cv')).to eq(1)
      end
    end

    it 'routes a known external platform through the engine only and an unknown one through the legacy steps' do
      legacy = %w[fetch_form fill_form submit]

      expect(active_keys(external: true, known: true, probable: false)).to include('detect', 'answer', 'verify:submit')
      expect(active_keys(external: true, known: true, probable: false) & legacy).to be_empty
      expect(active_keys(external: true, known: false, probable: false))
        .to eq(%w[check_applyable fetch_apply_type detect fetch_form fill_form generate_cv submit])
      expect(active_keys(external: false, known: false, probable: false))
        .to eq(%w[check_applyable fetch_apply_type fetch_form fill_form generate_cv submit])
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
