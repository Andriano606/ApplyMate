# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, type: :model do
  subject(:user) { described_class.new(email: unique_email("test"), name: "Test User", provider: "google_oauth2", uid: "123456") }

  describe "validations" do
    it { is_expected.to be_valid }

    it "requires email" do
      user.email = nil
      expect(user).not_to be_valid
    end

    it "requires name" do
      user.name = nil
      expect(user).not_to be_valid
    end

    it "requires provider" do
      user.provider = nil
      expect(user).not_to be_valid
    end

    it "requires uid" do
      user.uid = nil
      expect(user).not_to be_valid
    end

    it "requires uid to be unique within provider scope" do
      user.save!
      duplicate = described_class.new(email: unique_email("other"), name: "Other", provider: "google_oauth2", uid: "123456")
      expect(duplicate).not_to be_valid
    end

    it "allows same uid with different provider" do
      user.save!
      other_provider = described_class.new(email: unique_email("other"), name: "Other", provider: "github", uid: "123456")
      expect(other_provider).to be_valid
    end
  end
end

RSpec.describe User, "apply engine settings", type: :model do
  it "defaults review_policy to never and auto_consent to true" do
    user = create(:user).reload

    expect(user).to be_review_policy_never
    expect(user.auto_consent).to be(true)
  end

  it "maps the review policies" do
    expect(described_class.review_policies).to eq("always" => 0, "unknown_platforms" => 1, "never" => 2)
    expect(build(:user, review_policy: :always)).to be_review_policy_always
    expect(build(:user, review_policy: :unknown_platforms)).to be_review_policy_unknown_platforms
  end
end
