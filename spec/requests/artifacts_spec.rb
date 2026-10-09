# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Artifacts', type: :request do
  let(:user)    { create(:user) }
  let(:token)   { create(:api_token, user:) }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:pdf)     { { io: StringIO.new('%PDF-1.4'), filename: 'cv.pdf', content_type: 'application/pdf' } }

  describe 'GET /artifacts/apply/:id/cv' do
    let(:apply) { create(:apply, user:).tap { |a| a.cv.attach(pdf) } }

    it 'redirects the owner to a short-lived storage URL' do
      get artifact_path(owner: 'apply', id: apply.hashid, name: 'cv'), headers: headers

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include('/rails/active_storage/disk/')
    end

    it 'honours the attachment disposition' do
      get artifact_path(owner: 'apply', id: apply.hashid, name: 'cv', disposition: 'attachment'), headers: headers

      expect(response).to have_http_status(:redirect)
    end

    it "does not reveal another user's artifact" do
      other = create(:apply).tap { |a| a.cv.attach(pdf) }

      get artifact_path(owner: 'apply', id: other.hashid, name: 'cv'), headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it 'is not found when nothing is attached' do
      get artifact_path(owner: 'apply', id: apply.hashid, name: 'screenshot'), headers: headers

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route unknown owners or names' do
      get '/artifacts/user/abc/cv', headers: headers
      expect(response).to have_http_status(:not_found)

      get '/artifacts/apply/abc/secret', headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /artifacts/vacancy_cv/:id/cv' do
    let(:vacancy_cv) do
      create(:vacancy_cv, user_profile: create(:user_profile, user:)).tap { |cv| cv.cv.attach(pdf) }
    end

    it 'redirects the owner to a storage URL' do
      get artifact_path(owner: 'vacancy_cv', id: vacancy_cv.hashid, name: 'cv'), headers: headers

      expect(response).to have_http_status(:redirect)
    end

    it "does not reveal another user's CV" do
      other = create(:vacancy_cv).tap { |cv| cv.cv.attach(pdf) }

      get artifact_path(owner: 'vacancy_cv', id: other.hashid, name: 'cv'), headers: headers

      expect(response).to have_http_status(:not_found)
    end
  end
end
