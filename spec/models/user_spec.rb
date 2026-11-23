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

  describe '#unread_feedback_replies?' do
    let(:user)  { create(:user) }
    let(:admin) { create(:user, :admin) }

    it 'is false without a feedback' do
      expect(user.unread_feedback_replies?).to be(false)
    end

    it 'is false while nobody replied or only the author did' do
      feedback = create(:feedback, user:)
      create(:feedback_reply, feedback:, user:)

      expect(user.unread_feedback_replies?).to be(false)
    end

    it 'is true once somebody else replied, until the thread is read' do
      feedback = create(:feedback, user:)
      create(:feedback_reply, feedback:, user: admin)

      expect(user.unread_feedback_replies?).to be(true)

      feedback.read_new_replies!

      expect(user.unread_feedback_replies?).to be(false)
    end
  end
end
