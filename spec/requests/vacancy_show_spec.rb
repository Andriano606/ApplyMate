# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Vacancy page', type: :request do
  let(:vacancy) do
    create(:vacancy, source: create(:source), url: 'https://example.com/jobs/42',
                     description_html: '<p>Про нас</p><ul><li>Ruby</li></ul>')
  end

  def html
    Nokogiri::HTML(response.body)
  end

  def original_link
    html.at_css(%(a[href="#{vacancy.url}"][target="_blank"]))
  end

  shared_examples 'a vacancy page' do
    it 'renders the description and the original listing link' do
      expect(response).to have_http_status(:ok)
      expect(html.at_css('[data-test-id="vacancy-description"]').text).to include('Про нас')
      expect(original_link.text).to include(I18n.t('vacancy.show.open_original'))
    end

    it 'has no lazy frames or live streams' do
      expect(html.css('turbo-frame[src]')).to be_empty
      expect(html.css('turbo-cable-stream-source')).to be_empty
    end
  end

  context 'when signed in' do
    let(:user)    { create(:user) }
    let(:token)   { create(:api_token, user:) }
    let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

    before { get vacancy_path(vacancy), headers: }

    it_behaves_like 'a vacancy page'
  end

  context 'when a guest' do
    before { get vacancy_path(vacancy) }

    it_behaves_like 'a vacancy page'
  end

  context 'when the vacancy has no original link' do
    before do
      vacancy.update!(url: nil)
      get vacancy_path(vacancy)
    end

    it 'renders without the sidebar' do
      expect(response).to have_http_status(:ok)
      expect(html.at_css('aside')).to be_nil
    end
  end
end
