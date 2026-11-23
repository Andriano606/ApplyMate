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

  describe '#unread_feedback_reply_count' do
    let(:user)  { create(:user) }
    let(:admin) { create(:user, :admin) }

    it 'is 0 without a feedback or replies' do
      expect(user.unread_feedback_reply_count).to eq(0)
      create(:feedback, user:)
      expect(user.unread_feedback_reply_count).to eq(0)
    end

    it 'ignores the user\'s own replies' do
      create(:feedback_reply, feedback: create(:feedback, user:), user:)

      expect(user.unread_feedback_reply_count).to eq(0)
    end

    it 'counts replies by others under the own feedback until they are read' do
      feedback = create(:feedback, user:)
      2.times { create(:feedback_reply, feedback:, user: admin) }

      expect(user.unread_feedback_reply_count).to eq(2)

      FeedbackReply.read_unread!(user, [ feedback.id ])

      expect(user.unread_feedback_reply_count).to eq(0)
    end
  end
end
