# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Saved filters', type: :request do
  let(:user)  { create(:user) }
  let(:token) { user.api_tokens.create!.token }
  let(:headers) do
    { 'Authorization' => "Bearer #{token}",
      'Accept' => 'text/vnd.turbo-stream.html, text/html',
      'Referer' => 'http://www.example.com/vacancies' }
  end
  let(:saved_filter) do
    create(:saved_filter, user:, name: 'Embedded',
                          include_tags: %w[embedded], include_ops: [], exclude_tags: [])
  end

  it 'opens the edit modal prefilled with the preset name' do
    get edit_saved_filter_path(saved_filter), headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Embedded')
    expect(response.body).to include(saved_filter_path(saved_filter))
  end

  it 'opens the edit modal carrying the state currently in the search bar' do
    get edit_saved_filter_path(saved_filter, include_tags: %w[embedded remote], include_ops: %w[and]),
        headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('remote')
  end

  it 'updates the preset and answers with a page refresh' do
    patch saved_filter_path(saved_filter),
          params:  { saved_filter: { name: 'Embedded remote', include_tags: %w[embedded remote] } },
          headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('action="refresh"')

    expect(saved_filter.reload.name).to eq('Embedded remote')
    expect(saved_filter.include_tags).to eq(%w[embedded remote])
  end

  it 'saves into the preset in one click, keeping its name' do
    patch saved_filter_path(saved_filter, include_tags: %w[embedded remote], include_ops: %w[and]),
          headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('action="refresh"')

    expect(saved_filter.reload.include_tags).to eq(%w[embedded remote])
    expect(saved_filter.name).to eq('Embedded')
  end

  it 're-renders the modal with errors when the name is taken' do
    create(:saved_filter, user:, name: 'Taken')

    patch saved_filter_path(saved_filter),
          params:  { saved_filter: { name: 'Taken' } },
          headers: headers

    expect(saved_filter.reload.name).to eq('Embedded')
    expect(response.body).to include('saved_filter')
  end

  it 'refuses to edit a preset owned by another user' do
    other = create(:saved_filter)

    get edit_saved_filter_path(other), headers: headers

    expect(response).to have_http_status(:not_found)
  end
end
