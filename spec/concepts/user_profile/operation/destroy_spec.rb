# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserProfile::Operation::Destroy, type: :operation do
  let(:user)         { User.create!(email: "test@example.com", name: "Test User", provider: "google_oauth2", uid: "u1") }
  let(:user_profile) { UserProfile.create!(user: user, name: "My Profile", cv: "CV content") }
  let(:params)       { { id: user_profile.id } }
  let(:current_user) { user }

  it "destroys the profile" do
    user_profile
    expect { result }.to change(UserProfile, :count).by(-1)
    expect(result).to be_success
  end

  context "when the profile has associated applies" do
    let(:source)         { create(:source) }
    let(:vacancy)        { create(:vacancy, source: source) }
    let(:source_profile) { SourceProfile.create!(user: user, source: source, name: "SP", auth_method: :session_id) }
    let(:ai_integration) { AiIntegration.create!(user: user, provider: "gemini", model: "gemini-pro", api_key: "key") }

    before do
      Apply.create!(
        user:           user,
        vacancy:        vacancy,
        source_profile: source_profile,
        user_profile:   user_profile,
        ai_integration: ai_integration,
        status:         :generating_cv
      )
    end

    it "destroys the profile along with its applies" do
      expect { result }.to change(UserProfile, :count).by(-1)
                       .and change(Apply, :count).by(-1)
      expect(result).to be_success
    end
  end
end
