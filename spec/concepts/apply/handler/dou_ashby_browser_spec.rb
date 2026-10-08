# frozen_string_literal: true

require 'rails_helper'

# DOU external apply to an Ashby form, end to end through Job -> Handler::Dou -> Runner on the REAL browser
# (browserd) and FixtureSite (the Preply chain of design §16): dou.ua/goto -> 302 -> a company careers page with
# ?ashby_jid= (generic at the HTTP level, Ashby probable) -> survey lease: the landing page's embed iframe identifies
# Ashby, the schema is read, the canonical /application page is reached and its fields discovered -> answers (AI) ->
# CV -> review gate -> host slot -> submit lease: fill with read-back, claim, click, verify. Only the network outside
# FixtureSite is stubbed: the DOU / redirect / schema HTTP (ImpersonateHttp shells out to curl) and Gemini.
RSpec.describe Apply::Handler::Dou, :browser, type: :job do
  include ActiveJob::TestHelper
  include_context 'honeytech dou'

  let(:jid) { FixtureAshby::JID }
  let(:company_url) { FixtureSite.url("/ashby/company.html?ashby_jid=#{jid}") }
  let(:company_redirect) { nil } # a Location the company page answers with instead of its HTML
  let(:google_form) { 'https://docs.google.com/forms/d/e/1FAIpQLSf-test/viewform' }
  let(:http) { ApplyMate::Client::ImpersonateHttp.new }
  let(:posting) { ApplyMate::Client::Response.new(FixtureSite::ASHBY_POSTING_JSON.read, {}, 200, nil) }
  let(:opens) { [] }
  let(:claimed_at_post) { [] }
  let(:salary_path) { '596274cb-4e5f-4a6b-8c7d-9e0f1a2b3c08' }
  let(:gemini_cv) { gemini_json_response("```html\n<html><body><h1>Jane Doe</h1></body></html>\n```") }
  # Gemini in call order: AnswerFields, GenerateCv (Verify needs no AI: the page text and the GraphQL response are
  # two deterministic signals).
  let(:gemini_responses) { [ gemini_json_response(fixture_ashby_answers_json(email: user_email, phone: user_phone)), gemini_cv ] }

  def response(body, status: 200, location: nil)
    ApplyMate::Client::Response.new(body, location ? { 'location' => location } : {}, status, nil)
  end

  def run_job
    perform_enqueued_jobs { Apply::Job::Apply.perform_now(apply.id) }
    apply.reload
  end

  def submitted_values
    JSON.parse(FixtureSite.submissions.sole[:body]).dig('variables', 'values')
  end

  before do
    stub_fixture_ashby_registry
    allow(ApplyMate::Net::Operation::ResolvePublicAddress).to receive(:call) { |url:| FixtureSite.resolution(url) }
    allow(ApplyMate::Client::ImpersonateHttp).to receive(:new).and_return(http)
    pages = {
      HoneytechDou::VACANCY_URL => response(dou_vacancy_html),
      HoneytechDou::DOU_REDIRECT => response('', status: 302, location: company_url),
      company_url => company_redirect ? response('', status: 302, location: company_redirect) : response(
        FixtureSite::PAGES_DIR.join('ashby/company.html').read.gsub('{{ALT_ORIGIN}}', FixtureSite.alt_url(''))
      ),
      google_form => response('<html><body>Google Forms</body></html>')
    }
    allow(http).to receive(:get) { |url, **| pages.fetch(url) }
    allow(http).to receive(:post) do |url, **|
      raise "unexpected POST #{url}" unless url == "#{FixtureAshby.origin}/api/non-user-graphql?op=ApiJobPosting"

      posting
    end
    allow(ApplyMate::Client::Browser::Session).to receive(:open).and_wrap_original do |original, **options, &block|
      opens << options
      original.call(**options, &block)
    end
    FixtureSite.on_submit { |_submission| claimed_at_post << Apply.find(apply.id).submit_claimed_at }
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/).to_return(*gemini_responses)
  end

  it 'detects Ashby on the landing page, reaches the canonical form, fills it with read-back and submits once' do
    reloaded = run_job

    expect(reloaded).to have_attributes(state: 'completed', submitted_via: 'engine', platform: 'ashby',
                                        form_url: FixtureAshby.canonical_form_url, apply_key: "ashby:preply:#{jid}")
    expect(reloaded.platform_match).to include('key' => 'ashby', 'captures' => { 'slug' => 'preply', 'jid' => jid })
    expect(reloaded.field_list.map(&:id)).to all(start_with('ashby:'))
    expect(reloaded.field_list.size).to eq(15)
    expect(reloaded.field_list.map(&:id)).not_to include(a_string_matching(/autofill/i))
    expect(reloaded.apply_steps.chronological.map(&:key)).to eq(
      %w[check_applyable fetch_apply_type detect schema navigate:survey discover:survey answer generate_cv review
         throttle navigate:replay:submit discover:submit fill:submit submit:submit verify:submit]
    )
    expect(reloaded.apply_steps.map(&:state).uniq).to eq([ 'succeeded' ])
    expect(reloaded.navigation).to eq([ { 'op' => 'unwrap', 'url_template' => '{canonical_form_url}' } ])
    survey_navigation = reloaded.apply_steps.find_by!(key: 'navigate:survey').result['navigation']
    expect(survey_navigation.pluck('op')).to eq(%w[goto unwrap])

    expect(opens.map { |options| options[:humanize] }).to eq([ false, true ])
    expect(opens.pluck(:identity).uniq).to eq([ apply.hashid ])

    values = submitted_values
    expect(values).to include('_systemfield_name' => 'Jane Doe', '_systemfield_email' => user_email,
                              '6257e5b0-1d2a-4c55-9a51-3f0f2a6c1e01' => user_phone,
                              '9f2c7a14-5e3b-4d6a-8c1f-0a2b3c4d5e04' => 'LinkedIn', salary_path => '3500',
                              'c1d2e3f4-6a7b-4c8d-9e0f-1a2b3c4d5e10' => true)
    expect(values['_systemfield_resume']).to eq(reloaded.cv.filename.to_s)
    expect(values).to include('ab315a8b-7c2d-4e9f-8a1b-5c6d7e8f9a06' => '3-5 years', # opacity-0 radio
                              'c408722a-7b8c-4d9e-8f0a-2b3c4d5e6f11' => [ 'Acknowledge/Confirm' ], # GDPR by policy
                              '0b9874a9-3d4e-4f5a-9b6c-7d8e9f0a1b07' => '12')
    expect(values).not_to have_key('e5f6a7b8-8c9d-4e0f-9a1b-3c4d5e6f7a12') # the newsletter opt-in stays unticked
    expect(claimed_at_post).to contain_exactly(be_present)
    expect(reloaded.submit_claimed_at).to be <= reloaded.submitted_at
    expect(reloaded.screenshot).to be_attached

    expect { run_job }.not_to(change { [ ApplyStep.where(apply_id: apply.id).count, FixtureSite.submissions.size ] })
    expect(opens.size).to eq(2)
  end

  context 'when the user reviews every application (review_policy: always)' do
    # GeneratePdfCv has no input digest yet: it runs on the second attempt too.
    let(:gemini_responses) { [ gemini_json_response(fixture_ashby_answers_json(email: user_email, phone: user_phone)), gemini_cv, gemini_cv ] }

    before { user.update!(review_policy: :always) }

    it 'stops at the review, resumes after the approval without re-running detection, survey or answers' do
      expect(run_job).to have_attributes(state: 'needs_review', submit_claimed_at: nil)
      expect(apply.failure).to include('code' => 'review', 'detail' => 'policy_always')
      expect(opens.size).to eq(1)

      approved = Apply::Operation::ApproveReview.call(params: { id: apply.hashid, answers: { "ashby:#{salary_path}" => '4000' } },
                                                      current_user: user)
      expect(approved).to be_success
      expect(apply.reload).to be_queued
      perform_enqueued_jobs

      reloaded = apply.reload
      expect(reloaded).to have_attributes(state: 'completed', submitted_via: 'engine', attempt: 2)
      expect(reloaded.apply_steps.where(attempt: 2).chronological.map(&:key)).to eq(
        %w[check_applyable fetch_apply_type generate_cv review throttle navigate:replay:submit discover:submit
           fill:submit submit:submit verify:submit]
      )
      expect(opens.map { |options| options[:humanize] }).to eq([ false, true ])
      expect(submitted_values).to include(salary_path => '4000')
    end
  end

  context 'when the company page redirects to a Google Form' do
    let(:company_redirect) { google_form }

    it 'asks the user to apply themselves without opening a browser' do
      reloaded = run_job

      expect(reloaded).to be_needs_human
      expect(reloaded.failure).to include('code' => 'manual_apply_required', 'detail' => 'google_forms', 'stage' => 'detect')
      expect(reloaded.apply_steps.chronological.map(&:key)).to eq(%w[check_applyable fetch_apply_type detect])
      expect(opens).to be_empty
      expect(FixtureSite.submissions).to be_empty
    end
  end
end
