# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Vacancies index', type: :request do
  include_context 'with elasticsearch index'

  let(:marker) { 'data-test-id="total-vacancies"' }

  it 'renders the totals bar once on a full page load' do
    get '/vacancies', params: { include_tags: [ 'ruby' ] }

    expect(response).to have_http_status(:ok)
    expect(response.body.scan(marker).size).to eq(1)
  end

  # The endpoint replaces #vacancy-search with the whole component, so anything
  # rendered outside the frame would pile up on every search update.
  it 'keeps the totals bar inside the search frame so frame updates do not duplicate it' do
    get '/vacancies', params: { include_tags: [ 'ruby' ] }

    frame_start = response.body.index('vacancy-search')
    expect(frame_start).to be < response.body.index(marker)
  end

  it 'returns exactly one totals bar when the search bar updates the frame' do
    get '/vacancies',
        params:  { include_tags: [ 'ruby' ] },
        headers: { 'Turbo-Frame' => 'vacancy-search',
                   'Accept' => 'text/vnd.turbo-stream.html, text/html' }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('target="vacancy-search"')
    expect(response.body.scan(marker).size).to eq(1)
  end
end
