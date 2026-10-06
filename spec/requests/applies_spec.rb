# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Applies on the vacancy page', type: :request do
  let(:user)    { create(:user) }
  let(:token)   { create(:api_token, user:) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:vacancy) { create(:vacancy, source: create(:source)) }
  let!(:apply)  { create(:apply, user:, vacancy:, status: :completed) }

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
        { 'name' => 'email', 'tag' => 'input', 'type' => 'email', 'label' => 'Email', 'value' => 'dev@example.com' },
        { 'name' => 'token', 'tag' => 'input', 'type' => 'hidden', 'value' => 'secret-token' }
      ]
    end
    let!(:failed_apply) do
      create(:apply, user:, vacancy:, status: :failed_sending_cv, error: 'Submit button not found',
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

    it 'shows the error and the filled form of an apply' do
      get vacancy_applies_path(vacancy), headers: headers

      card = html.at_css("#apply_#{failed_apply.hashid}")
      expect(card.at_css('[role="alert"]').text).to include(I18n.t('apply.card.error_title'), 'Submit button not found')
      expect(card.at_css('textarea[aria-label="Why us?"]').text.strip).to eq('Because Ruby')
      expect(card.at_css('input[aria-label="Email"]')['value']).to eq('dev@example.com')
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
end
