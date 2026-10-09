# frozen_string_literal: true

require 'rails_helper'

# DOU external apply to a site NO adapter knows, end to end through Job -> Handler::Dou -> Runner on the REAL browser
# (browserd) and FixtureSite: dou.ua/goto -> 302 -> generic/careers.html (generic at the HTTP level and on the rendered
# page) -> survey lease: the cookie banner is accepted by the gate, the AI Navigator clicks the "Apply" tab inside the
# cross-origin widget iframe and claims the form (R2 + origin) -> page-1 fields discovered in frame f1 -> answers (AI)
# -> CV -> review gate -> host slot -> submit lease: the stored navigation is replayed through Recipe::Interpret (no
# Navigator), page 1 is filled with read-back (an Element-UI-like select among them), Next is classified :next ("Step 1
# of 2"), page 2's follow-up fields are answered (contenteditable cover letter, file, consent) and filled, "Submit
# application" is :final -> claim -> click -> one JSON POST -> verify (thank-you text + AI corroboration).
#
# Only the network outside FixtureSite is stubbed: the DOU / redirect HTTP (ImpersonateHttp shells out to curl) and
# Gemini. The Gemini stub is the shared router of the 'honeytech dou' context (stub_gemini_router): it reads the
# prompt it gets and Navigate turns answer with refs PARSED from the prompt text (never hard-coded), so the AI sees
# exactly what production would show it.
RSpec.describe Apply::Handler::Dou, :browser, type: :job do
  include ActiveJob::TestHelper
  include_context 'honeytech dou'

  let(:careers_url) { FixtureSite.url('/generic/careers.html') }
  let(:http) { ApplyMate::Client::ImpersonateHttp.new }
  let(:opens) { [] }
  let(:claimed_at_post) { [] }
  # The shared Gemini router (honeytech_dou.rb) answers the widget's English labels and cites the fixture's thank-you.
  let(:verify_quote) { 'We received your application.' }
  let(:answers_by_label) do
    { 'Full name' => 'Jane Doe', 'Email' => user_email, 'Phone' => user_phone, 'How did you hear about us?' => 'LinkedIn',
      'Cover letter' => cover_letter }
  end

  def response(body, status: 200, location: nil)
    ApplyMate::Client::Response.new(body, location ? { 'location' => location } : {}, status, nil)
  end

  def run_job
    perform_enqueued_jobs { Apply::Job::Apply.perform_now(apply.id) }
    apply.reload
  end

  def submitted
    JSON.parse(FixtureSite.submissions.sole[:body])
  end

  before do
    allow(ApplyMate::Client::ImpersonateHttp).to receive(:new).and_return(http)
    careers = FixtureSite::PAGES_DIR.join('generic/careers.html').read
                                    .gsub('{{ORIGIN}}', FixtureSite.url('')).gsub('{{ALT_ORIGIN}}', FixtureSite.alt_url(''))
    pages = {
      HoneytechDou::VACANCY_URL => response(dou_vacancy_html),
      HoneytechDou::DOU_REDIRECT => response('', status: 302, location: careers_url),
      careers_url => response(careers)
    }
    allow(http).to receive(:get) { |url, **| pages.fetch(url) }
    allow(http).to receive(:post) { |url, **| raise "unexpected POST #{url}" }
    allow(ApplyMate::Client::Browser::Session).to receive(:open).and_wrap_original do |original, **options, &block|
      opens << options
      original.call(**options, &block)
    end
    FixtureSite.on_submit { |_submission| claimed_at_post << Apply.find(apply.id).submit_claimed_at }
    stub_gemini_router
  end

  it 'navigates into the iframe with the AI, fills both wizard pages with read-back, claims and posts once' do
    reloaded = run_job

    expect(reloaded).to have_attributes(state: 'completed', submitted_via: 'engine', platform: 'generic', apply_key: nil,
                                        form_url: careers_url, failure: nil)
    expect(reloaded.apply_steps.chronological.map(&:key)).to eq(
      %w[check_applyable fetch_apply_type detect schema navigate:survey discover:survey answer generate_cv review
         throttle navigate:replay:submit discover:submit fill:submit submit:submit verify:submit]
    )
    expect(reloaded.apply_steps.map(&:state).uniq).to eq([ 'succeeded' ])

    # navigation: the landing goto, the AI's tab click, the terminal wait_for; templates only, no fill, no literal URL
    expect(reloaded.navigation.pluck('op')).to eq(%w[goto click wait_for])
    expect(reloaded.navigation.first).to eq('op' => 'goto', 'url_template' => '{landing_url}')
    expect(reloaded.navigation.to_json).not_to include(FixtureSite.host)
    expect(reloaded.navigation.second.dig('target', 'frame_path')).to be_present # the tab lives in the widget iframe

    fields = reloaded.field_list.index_by(&:label)
    expect(fields.keys).to include('Full name', 'Email', 'Phone', 'How did you hear about us?', 'Cover letter', 'Resume',
                                   'I agree to the privacy policy')
    expect(fields.values.map { |field| field.target&.frame_path }.compact.uniq.size).to eq(1)
    expect(fields.values.filter_map(&:target).map(&:frame_path)).to all(be_present) # all in the iframe (f1)
    expect(fields['How did you hear about us?'].widget).to eq('aria_combobox')
    expect(fields['Cover letter'].widget).to eq('content_editable')
    expect(fields['Resume'].widget).to eq('file_input')
    expect(fields['Cover letter']).to be_later_page

    # the AI: the Navigator's turns in the survey (click, maybe a wait for the widget to mount, form_reached), the
    # answers, the CV, the page-2 follow-up, the verify corroboration
    expect(gemini_prompt_kinds.count(:navigate)).to be_between(2, 3)
    expect(gemini_prompt_kinds.drop_while { |kind| kind == :navigate }).to eq(%i[answers cv answers verify])
    expect(reloaded.ai_calls_total).to be_between(4, 8)
    expect(reloaded.ai_calls).to eq(reloaded.ai_calls_total) # one attempt
    advances = reloaded.apply_steps.find_by!(key: 'fill:submit').result
    expect(advances).to include('pages' => 2)

    # read-back proved by what the site received: page-1 values travelled on through Next
    expect(submitted).to include('full_name' => 'Jane Doe', 'email' => user_email, 'phone' => user_phone,
                                 'source' => 'LinkedIn', 'cover_letter' => cover_letter, 'consent' => true,
                                 'resume' => reloaded.cv.filename.to_s)
    expect(FixtureSite.submissions.sole[:op]).to eq('generic')
    expect(claimed_at_post).to contain_exactly(be_present)
    expect(reloaded.submit_claimed_at).to be <= reloaded.submitted_at
    expect(opens.map { |options| options[:humanize] }).to eq([ false, true ])

    expect { run_job }.not_to(change { [ ApplyStep.where(apply_id: apply.id).count, FixtureSite.submissions.size ] })
  end

  context 'when the user reviews unknown platforms (review_policy: unknown_platforms)' do
    before { user.update!(review_policy: :unknown_platforms) }

    def approve!
      expect(Apply::Operation::ApproveReview.call(params: { id: apply.hashid }, current_user: user)).to be_success
      perform_enqueued_jobs
      apply.reload
    end

    # The approval is bound to the answers the user saw: page 2's follow-up answers (asked in the submit scope) re-open
    # the review before page 2 is filled; the third attempt fills the approved answers and submits.
    it 'reviews before the submit lease and again for the page-2 answers, replays without the Navigator, submits once' do
      expect(run_job).to have_attributes(state: 'needs_review', submit_claimed_at: nil)
      expect(apply.failure).to include('code' => 'review', 'detail' => 'unknown_platform', 'stage' => 'review')
      expect(opens.size).to eq(1)
      survey_prompts = gemini_prompts.size

      expect(approve!).to have_attributes(state: 'needs_review', attempt: 2, submit_claimed_at: nil)
      expect(apply.failure).to include('code' => 'review', 'detail' => 'unknown_platform', 'stage' => 'fill')
      expect(apply.field_list.find { |field| field.label == 'Cover letter' }).to be_later_page
      expect(FixtureSite.submissions).to be_empty
      attempt_two_prompts = gemini_prompts.size

      reloaded = approve!
      expect(reloaded).to have_attributes(state: 'completed', submitted_via: 'engine', attempt: 3)
      expect(gemini_prompt_kinds.drop(survey_prompts)).not_to include(:navigate) # the stored navigation replays through Interpret
      expect(gemini_prompt_kinds.drop(attempt_two_prompts)).to eq(%i[cv verify]) # the approved page-2 answers are not asked again
      expect(reloaded.ai_calls).to be <= 4
      expect(reloaded.apply_steps.find_by!(attempt: 3, key: 'navigate:replay:submit').result['navigation'].pluck('op'))
        .to eq(%w[goto click wait_for])
      expect(opens.map { |options| options[:humanize] }).to eq([ false, true, true ])
      expect(submitted).to include('email' => user_email, 'cover_letter' => cover_letter)
      expect(claimed_at_post).to contain_exactly(be_present)
    end
  end
end
