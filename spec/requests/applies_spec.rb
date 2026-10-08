# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Applies on the vacancy page', type: :request do
  let(:user)    { create(:user) }
  let(:token)   { create(:api_token, user:) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:vacancy) { create(:vacancy, source: create(:source)) }
  let(:filled_email) { unique_email }
  let!(:apply)  { create(:apply, :completed, user:, vacancy:) }

  def html
    Nokogiri::HTML(response.body)
  end

  describe 'GET /applies/:id' do
    it 'redirects to the apply card on the vacancy page' do
      get apply_path(apply), headers: headers

      expect(response).to redirect_to(vacancy_path(vacancy, anchor: "apply_#{apply.hashid}"))
    end

    it "does not reveal another user's apply" do
      other_apply = create(:apply, vacancy:)

      get apply_path(other_apply), headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /vacancies/:vacancy_id/applies' do
    let(:filled_inputs) do
      [
        { 'name' => 'why', 'tag' => 'textarea', 'type' => 'textarea', 'label' => 'Why us?', 'value' => 'Because Ruby' },
        { 'name' => 'email', 'tag' => 'input', 'type' => 'email', 'label' => 'Email', 'value' => filled_email },
        { 'name' => 'token', 'tag' => 'input', 'type' => 'hidden', 'value' => 'secret-token' }
      ]
    end
    let!(:failed_apply) do
      create(:apply, :failed, user:, vacancy:, failure: { code: 'outcome_unknown', kind: 'permanent' },
                              filled_inputs:, created_at: 1.minute.from_now)
    end

    it "renders the user's applies panel frame" do
      get vacancy_applies_path(vacancy), headers: headers

      expect(response).to have_http_status(:ok)
      expect(html.at_css("turbo-frame#vacancy_applies_#{vacancy.hashid}_#{user.hashid}")).to be_present
    end

    it "lists only the current user's applies for this vacancy, newest first" do
      other_users_apply   = create(:apply, vacancy:)
      other_vacancy_apply = create(:apply, user:)

      get vacancy_applies_path(vacancy), headers: headers

      card_ids = html.css('article[id^="apply_"]').pluck('id')
      expect(card_ids).to eq([ "apply_#{failed_apply.hashid}", "apply_#{apply.hashid}" ])
      expect(response.body).not_to include("apply_#{other_users_apply.hashid}")
      expect(response.body).not_to include("apply_#{other_vacancy_apply.hashid}")
    end

    it 'shows the failure and the filled form of an apply' do
      get vacancy_applies_path(vacancy), headers: headers

      card = html.at_css("#apply_#{failed_apply.hashid}")
      expect(card.at_css('[role="alert"]').text).to include(I18n.t('apply.failure.outcome_unknown'), I18n.t('apply.failure_hint.outcome_unknown'))
      expect(card.at_css('textarea[aria-label="Why us?"]').text.strip).to eq('Because Ruby')
      expect(card.at_css('input[aria-label="Email"]')['value']).to eq(filled_email)
      expect(card.to_html).not_to include('secret-token')
    end

    it 'offers to generate an answer for each open question of the filled form' do
      get vacancy_applies_path(vacancy), headers: headers

      card = html.at_css("#apply_#{failed_apply.hashid}")
      answer_links = card.css('a[data-turbo-stream]').select { |a| a.text.include?(I18n.t('apply.card.generate_answer')) }
      expect(answer_links.pluck('href'))
        .to eq([ new_vacancy_vacancy_question_path(vacancy, vacancy_question: { question: 'Why us?' }) ])
    end

    it 'shows the empty state with an apply call to action when the user has not applied' do
      other_vacancy = create(:vacancy, source: create(:source))

      get vacancy_applies_path(other_vacancy), headers: headers

      expect(response.body).to include(I18n.t('apply.vacancy_index.empty'))
      expect(html.at_css(%(a[href="#{new_apply_path(vacancy_id: other_vacancy.hashid)}"][data-turbo-stream]))).to be_present
    end
  end

  describe 'DELETE /applies/:id' do
    it 'removes the apply and refreshes the vacancy page views' do
      allow(Apply::TurboHandler::StatusUpdate).to receive(:refresh)
      allow(VacancyCv::TurboHandler::Index).to receive(:broadcast)

      delete apply_path(apply), headers: headers.merge('Accept' => 'text/vnd.turbo-stream.html')

      expect(response.body).to include(%(action="remove_by_id" target="#{apply.id}"))
      expect(Apply.exists?(apply.id)).to be(false)
      expect(Apply::TurboHandler::StatusUpdate).to have_received(:refresh).with(vacancy, user)
      expect(VacancyCv::TurboHandler::Index).to have_received(:broadcast).with(vacancy, user)
    end
  end

  describe 'member actions' do
    let(:stream_headers) { headers.merge('Accept' => 'text/vnd.turbo-stream.html') }

    before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

    def flash_stream
      response.body
    end

    describe 'POST /applies/:id/resume' do
      let!(:failed_apply) { create(:apply, :failed, user:, vacancy: create(:vacancy, source: create(:source))) }

      it 're-queues the apply and answers with a flash stream' do
        expect { post resume_apply_path(failed_apply), headers: stream_headers }
          .to have_enqueued_job(Apply::Job::Apply).with(failed_apply.id)

        expect(response).to have_http_status(:ok)
        expect(flash_stream).to include('<turbo-stream').and include(I18n.t('apply.resume.success'))
        expect(failed_apply.reload).to be_queued
      end

      it 'answers with an error flash when the apply cannot be resumed' do
        failed_apply.update_columns(state: Apply.states[:submit_unverified])

        post resume_apply_path(failed_apply), headers: stream_headers

        expect(flash_stream).to include(I18n.t('apply.resume.not_allowed'))
      end

      it "does not reveal another user's apply" do
        post resume_apply_path(create(:apply, :failed)), headers: stream_headers

        expect(response).to have_http_status(:not_found)
      end
    end

    describe 'POST /applies/:id/cancel' do
      it 'cancels a queued apply and flashes' do
        queued = create(:apply, user:, vacancy: create(:vacancy, source: create(:source)))

        post cancel_apply_path(queued), headers: stream_headers

        expect(flash_stream).to include(I18n.t('apply.cancel.success'))
        expect(queued.reload).to be_cancelled
      end
    end

    describe 'POST /applies/:id/approve_review' do
      let!(:waiting) do
        create(:apply, user:, vacancy: create(:vacancy, source: create(:source)), state: :needs_review,
                       fields: [ answer_field(id: 'why', kind: 'textarea', label: 'Why us?').to_h ],
                       answers: { 'why' => answer_entry('Because', confidence: 0.2) })
      end

      it 'approves the edited answers, re-queues the apply and flashes' do
        expect { post approve_review_apply_path(waiting, answers: { why: 'My words' }), headers: stream_headers }
          .to have_enqueued_job(Apply::Job::Apply).with(waiting.id)

        expect(flash_stream).to include(I18n.t('apply.approve_review.success'))
        expect(waiting.reload).to be_queued
        expect(waiting.answers.dig('why', 'value')).to eq('My words')
      end

      it "does not reveal another user's apply" do
        post approve_review_apply_path(create(:apply, state: :needs_review)), headers: stream_headers

        expect(response).to have_http_status(:not_found)
      end
    end

    describe 'POST /applies/:id/mark_outcome' do
      let!(:unverified) { create(:apply, :claimed, user:, vacancy: create(:vacancy, source: create(:source))) }

      it 'completes the apply for the manual outcome' do
        post mark_outcome_apply_path(unverified, outcome: 'manual'), headers: stream_headers

        expect(flash_stream).to include(I18n.t('apply.mark_outcome.success.manual'))
        expect(unverified.reload).to be_completed
      end

      it 'asks for confirmation on not_sent' do
        post mark_outcome_apply_path(unverified, outcome: 'not_sent'), headers: stream_headers

        expect(flash_stream).to include(I18n.t('apply.mark_outcome.confirm_required'))
        expect(unverified.reload).to be_submit_unverified
      end
    end
  end

  describe 'GET /applies with the attention filter' do
    let(:other_vacancy) { create(:vacancy, source: create(:source), title: 'Attention Vacancy') }
    let!(:failed_apply) { create(:apply, :failed, user:, vacancy: other_vacancy) }

    it 'lists only applies that need attention' do
      get applies_path(filter: 'attention'), headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(other_vacancy.title)
      expect(response.body).not_to include(vacancy.title)
    end

    it 'renders the filter tabs with the attention count' do
      get applies_path(filter: 'attention'), headers: headers

      tabs = html.css('[data-test-id="apply-filter-tabs"] a')
      expect(tabs.map { |a| a.text.strip }).to eq([ I18n.t('apply.index.filter.all'), I18n.t('apply.index.filter.attention', count: 1) ])
    end

    it 'shows the red attention count in the navbar, and nothing for a user without attention applies' do
      get applies_path, headers: headers
      expect(html.css('nav.sticky a[href="/applies?filter=attention"] span.bg-red-100')).not_to be_empty

      failed_apply.update!(state: :completed)
      user.touch(:applies_changed_at)
      get applies_path, headers: headers
      expect(html.css('nav.sticky a[href="/applies?filter=attention"]')).to be_empty
      expect(html.css('nav.sticky span.bg-red-600')).to be_empty
    end
  end
end
