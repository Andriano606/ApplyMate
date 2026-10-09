# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Handler::Dou do
  context 'DOU external apply (HoneyTech: PeopleForce, a platform no adapter knows)' do
    include_context 'honeytech dou'

    let(:engine_keys) do
      %w[check_applyable fetch_apply_type detect schema navigate:survey discover:survey answer generate_cv review throttle
         navigate:replay:submit discover:submit fill:submit submit:submit verify:submit]
    end
    let(:claimed_at_click) { [] }

    def submit_click?(target)
      target.strategies.any? { |strategy| strategy['css'] == HoneytechDou::PEOPLEFORCE_SUBMIT }
    end

    before do
      # DOU vacancy page — used by CheckApplyable, FetchApplyType. Dou's scraper client is ImpersonateHttp (Chrome
      # TLS to clear Cloudflare); it shells out to curl-impersonate and bypasses WebMock, so stub it at the client level.
      allow_any_instance_of(ApplyMate::Client::ImpersonateHttp).to receive(:get)
        .with(HoneytechDou::VACANCY_URL, any_args)
        .and_return(ApplyMate::Client::Response.new(dou_vacancy_html, {}, 200, HoneytechDou::VACANCY_URL))
      stub_honeytech_redirect_walk
      # Gemini answers by prompt kind: Navigate (form_reached with the refs listed in the prompt), AnswerFields,
      # GenerateCv, VerifySubmit.
      stub_gemini_router
      session.on(:click) { |target| claimed_at_click << Apply.find(apply.id).submit_claimed_at if submit_click?(target) }
    end

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

      it 'detects PeopleForce as generic and reaches its form with the Navigator in one non-humanized survey lease' do
        run_handler
        reloaded = apply.reload

        expect(reloaded).to have_attributes(platform: 'generic', entry_url: HoneytechDou::DOU_REDIRECT, apply_key: nil,
                                            form_url: HoneytechDou::PEOPLEFORCE_URL)
        expect(reloaded.platform_match).to include('key' => 'generic', 'probable' => nil)
        detect = reloaded.apply_steps.find_by!(key: 'detect')
        expect(detect.result.dig('evidence', 'hops')).to eq([ HoneytechDou::DOU_REDIRECT, HoneytechDou::PEOPLEFORCE_URL ])
        expect(session.open_options.first).to include(humanize: false)
        expect(gemini_prompt_kinds.first).to eq(:navigate)
        expect(gemini_prompt_kinds.count(:navigate)).to eq(1) # the form is on the landing page: one form_reached turn
        expect(reloaded.navigation.pluck('op')).to eq(%w[goto wait_for])
        expect(reloaded.navigation.first).to eq('op' => 'goto', 'url_template' => '{landing_url}')
        expect(reloaded.navigation.last).to include('root' => HoneytechDou::PEOPLEFORCE_FORM)
      end

      it 'discovers the PeopleForce fields from the snapshot and answers them' do
        run_handler
        fields = apply.reload.field_list.index_by(&:label)

        expect(fields.keys).to include("Повне ім'я", 'Електронна пошта', 'Номер телефону', 'Супровідний лист', 'Резюме')
        expect(fields['Супровідний лист'].widget).to eq('content_editable')
        expect(fields['Резюме'].widget).to eq('file_input')
        expect(apply.answers.values.pluck('value')).to include(user_email, user_phone, cover_letter)
      end

      it 'completes through the Runner: the engine steps only, the claim before the submit click, then verified' do
        run_handler
        reloaded = apply.reload

        expect(reloaded).to have_attributes(state: 'completed', stage: nil, failure: nil, submitted_via: 'engine')
        expect(reloaded.apply_steps.chronological.map { |step| [ step.key, step.state, step.attempt ] })
          .to eq(engine_keys.map { |key| [ key, 'succeeded', 1 ] })
        expect(reloaded.inputs).to be_nil # the internal HTTP steps never ran
        expect(claimed_at_click).to contain_exactly(be_present)
        expect(reloaded.submit_claimed_at).to be <= reloaded.submitted_at
        expect(reloaded.cv).to be_attached
        expect(gemini_prompt_kinds).to eq(%i[navigate answers cv verify])
        expect(reloaded.ai_calls).to eq(3) # Navigate, AnswerFields, VerifySubmit go through CallAi; the CV does not
      end

      it 'opens the survey lease, then a separate humanized submit lease, each landing on the redirect walk\'s final URL' do
        run_handler
        expect(session.open_options.map { |options| options[:humanize] }).to eq([ false, true ])
        expect(session.calls_of(:goto)).to eq([ [ HoneytechDou::PEOPLEFORCE_URL ], [ HoneytechDou::PEOPLEFORCE_URL ] ])
      end

      it 'fills with read-back and clicks the submit button with the Ukrainian label, once' do
        run_handler
        expect(session.calls_of(:fill).map(&:last) + session.calls_of(:type).map { |call| call[1] })
          .to include('Jane Doe', user_email, user_phone, cover_letter)
        expect(session.calls_of(:upload).sole.second).to end_with('.pdf')
        expect(session.calls_of(:click).map(&:first).count { |target| submit_click?(target) }).to eq(1)
      end

      # Owner decision 2026-10-09: no integration is refused; a browser-backed one runs the Navigator in text mode,
      # inside a lease too.
      context 'with a GeminiScraping integration (browser-backed, text mode)' do
        let(:scraping_client) { instance_double(ApplyMate::Ai::Client::GeminiScraping) }

        before do
          ai_integration.update!(provider: 'gemini_scraping')
          allow(ApplyMate::Ai::Client::GeminiScraping).to receive(:new).and_return(scraping_client)
          allow(scraping_client).to receive(:complete) do |request|
            prompt = [ request.system, *request.messages.map { |message| message[:content] } ].compact.join("\n\n")
            ApplyMate::Ai::Response.new(text: gemini_route(prompt), usage: ApplyMate::Ai::Usage::UNKNOWN)
          end
        end

        it 'is not halted at detect: the Navigator runs and the apply completes with the browser-backed AI' do
          run_handler
          reloaded = apply.reload

          expect(reloaded.failure).to be_nil
          expect(reloaded).to have_attributes(state: 'completed', platform: 'generic')
          expect(reloaded.apply_steps.chronological.map { |step| [ step.key, step.state ] })
            .to eq(engine_keys.map { |key| [ key, 'succeeded' ] })
          expect(gemini_prompt_kinds).to eq(%i[navigate answers cv verify])
          expect(scraping_client).to have_received(:complete).exactly(4).times
          expect(a_request(:post, /generativelanguage/)).not_to have_been_made
        end
      end

      context 'when the vacancy page has no reply button' do
        before do
          allow_any_instance_of(ApplyMate::Scraper::Dou).to receive(:fetch_applyble).and_return(false)
        end

        it 'ends unsupported at check_applyable without opening a browser' do
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
      expect(reloaded.inputs).to be_nil # the internal HTTP steps never ran
    end

    context 'with a GeminiScraping integration (a known platform: the deterministic route asks no AI in the lease)' do
      let(:scraping_client) { instance_double(ApplyMate::Ai::Client::GeminiScraping) }

      before do
        ai_integration.update!(provider: 'gemini_scraping')
        allow(ApplyMate::Ai::Client::GeminiScraping).to receive(:new).and_return(scraping_client)
        # In call order: AnswerFields, GenerateCv; each asserts no browser lease is open while the AI is asked.
        texts = [ fixture_ashby_answers_json(email: user_email, phone: user_phone),
                  "```html\n<html><body><h1>Jane Doe</h1></body></html>\n```" ]
        allow(scraping_client).to receive(:complete) do
          expect(session.open_options).to be_empty
          ApplyMate::Ai::Response.new(text: texts.shift, usage: ApplyMate::Ai::Usage::UNKNOWN)
        end
      end

      it 'is not halted at detect and reaches the answers, the CV and the review (deterministic navigation)' do
        described_class.new(apply:).call
        reloaded = apply.reload

        expect(reloaded).to have_attributes(state: 'needs_review', platform: 'ashby')
        expect(reloaded.failure).to include('code' => 'review', 'stage' => 'review')
        steps = reloaded.apply_steps.chronological.map { |step| [ step.key, step.state ] }
        expect(steps).to eq(%w[check_applyable fetch_apply_type detect schema answer generate_cv].map { |key| [ key, 'succeeded' ] } +
                            [ %w[review failed] ]) # review_policy: :always stops the run before the submit scope
        expect(reloaded.answers.keys).to include('ashby:_systemfield_email')
        expect(reloaded.cv).to be_attached
        expect(scraping_client).to have_received(:complete).twice
      end
    end
  end

  describe 'step conditions' do
    # apply_steps is unique on (apply_id, attempt, key): for both apply types the steps that may run share no key, and
    # the CV is generated by exactly one generate_cv step (the engine's or the internal one).
    def active_keys(external:)
      ctx = instance_double(Apply::Operation::Engine::Context,
                            apply: instance_double(Apply, external?: external, internal?: !external), survey_needed?: true)
      described_class.steps.select do |step|
        scope_condition = step.scope && described_class.scope_conditions[step.scope]
        [ step.condition, scope_condition ].compact.all? { |condition| condition.call(ctx) }
      end.map(&:key)
    end

    [ true, false ].each do |external|
      it "never runs two steps with one key (external: #{external})" do
        keys = active_keys(external:)

        expect(keys).to eq(keys.uniq)
        expect(keys.count('generate_cv')).to eq(1)
      end
    end

    it 'routes every external apply through the engine and an internal one through the HTTP steps' do
      expect(active_keys(external: true)).to eq(
        %w[check_applyable fetch_apply_type detect schema navigate:survey discover:survey answer generate_cv review
           throttle navigate:replay:submit discover:submit fill:submit submit:submit verify:submit]
      )
      expect(active_keys(external: false))
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
