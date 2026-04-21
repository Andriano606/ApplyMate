# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, type: :model do
  subject(:user) { described_class.new(email: "test@example.com", name: "Test User", provider: "google_oauth2", uid: "123456") }

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
      duplicate = described_class.new(email: "other@example.com", name: "Other", provider: "google_oauth2", uid: "123456")
      expect(duplicate).not_to be_valid
    end

    it "allows same uid with different provider" do
      user.save!
      other_provider = described_class.new(email: "other@example.com", name: "Other", provider: "github", uid: "123456")
      expect(other_provider).to be_valid
    end
  end
end
