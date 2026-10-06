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

  context 'when signed in' do
    let(:user)    { create(:user) }
    let(:token)   { create(:api_token, user:) }
    let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }

    before { get vacancy_path(vacancy), headers: }

    it 'lazy-loads the applies, CVs and questions frames from their own endpoints' do
      expect(response).to have_http_status(:ok)
      expect(html.at_css("turbo-frame#vacancy_applies_#{vacancy.hashid}_#{user.hashid}")['src'])
        .to eq(vacancy_applies_path(vacancy))
      expect(html.at_css("turbo-frame#vacancy_cvs_#{vacancy.hashid}")['src']).to eq(vacancy_vacancy_cvs_path(vacancy))
      expect(html.at_css("turbo-frame#vacancy_questions_#{vacancy.hashid}")['src'])
        .to eq(vacancy_vacancy_questions_path(vacancy))
    end

    # Badge, action box and applies panel all ride one [user, vacancy] stream.
    it 'subscribes to the [user, vacancy] stream exactly once' do
      signed_stream = Turbo::StreamsChannel.signed_stream_name([ user, vacancy ])

      expect(html.css(%(turbo-cable-stream-source[signed-stream-name="#{signed_stream}"])).size).to eq(1)
    end

    it 'renders the description, the apply call to action and the original listing link' do
      expect(html.at_css('[data-test-id="vacancy-description"]').text).to include('Про нас')
      expect(html.at_css('[data-test-id="apply-action-box"]').text).to include(I18n.t('apply.action_box.apply'))
      expect(original_link.text).to include(I18n.t('vacancy.show.open_original'))
    end
  end

  context 'when a guest' do
    before { get vacancy_path(vacancy) }

    it 'renders the description and the original listing link without the personal workspace' do
      expect(response).to have_http_status(:ok)
      expect(html.at_css('[data-test-id="vacancy-description"]').text).to include('Про нас')
      expect(original_link).to be_present
      expect(html.at_css(%(a[href="#{login_path}"]))).to be_present
      expect(html.css('turbo-frame[src]')).to be_empty
      expect(html.at_css('#vacancy-applies, #vacancy-cvs, #vacancy-questions')).to be_nil
      expect(html.css('turbo-cable-stream-source')).to be_empty
    end
  end
end
