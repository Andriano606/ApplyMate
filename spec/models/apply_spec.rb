# frozen_string_literal: true

require "rails_helper"

RSpec.describe Apply, type: :model do
  let(:source1) { create(:source, name: "Source 1") }
  let(:source2) { create(:source, name: "Source 2") }
  let(:user) { User.create!(email: "test@example.com", name: "Test User", provider: "google_oauth2", uid: "123") }
  let(:vacancy) { create(:vacancy, source: source1) }
  let(:source_profile) { SourceProfile.create!(user: user, source: source1, name: "Profile 1", auth_method: :session_id) }
  let(:user_profile) { UserProfile.create!(user: user, name: "User Profile", cv: "My CV") }
  let(:ai_integration) { AiIntegration.create!(user: user, provider: "gemini", model: "gemini-pro", api_key: "secret") }

  subject(:apply) do
    described_class.new(
      user: user,
      vacancy: vacancy,
      source_profile: source_profile,
      user_profile: user_profile,
      ai_integration: ai_integration,
      status: :pending
    )
  end

  describe "validations" do
    context "when source_profile and vacancy have the same source" do
      it "is valid" do
        expect(apply).to be_valid
      end
    end

    context "when source_profile and vacancy have different sources" do
      let(:vacancy) { create(:vacancy, source: source2) }

      it "is invalid" do
        expect(apply).not_to be_valid
        expect(apply.errors[:source_profile]).to include("must belong to the same source as the vacancy")
      end
    end

    context "when vacancy is missing" do
      before { apply.vacancy = nil }

      it "does not add source mismatch error" do
        apply.valid?
        expect(apply.errors[:source_profile]).not_to include("must belong to the same source as the vacancy")
      end
    end

    context "when source_profile is missing" do
      before { apply.source_profile = nil }

      it "does not add source mismatch error" do
        apply.valid?
        expect(apply.errors[:source_profile]).not_to include("must belong to the same source as the vacancy")
      end
    end
  end
end
