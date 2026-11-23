# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Feedback do
  subject(:feedback) { build(:feedback) }

  it { is_expected.to be_valid }

  describe 'validations' do
    it 'requires a rating between 1 and 10' do
      [ 0, 11, nil ].each do |rating|
        feedback.rating = rating
        expect(feedback).not_to be_valid
        expect(feedback.errors[:rating]).to be_present
      end
      [ 1, 10 ].each do |rating|
        feedback.rating = rating
        expect(feedback).to be_valid
      end
    end

    it 'requires a body of at most 2000 characters' do
      feedback.body = ''
      expect(feedback).not_to be_valid

      feedback.body = 'a' * 2001
      expect(feedback).not_to be_valid

      feedback.body = 'a' * 2000
      expect(feedback).to be_valid
    end

    it 'accepts only web or mcp as the source' do
      feedback.posted_via = 'email'
      expect(feedback).not_to be_valid

      feedback.posted_via = 'mcp'
      expect(feedback).to be_valid
    end

    it 'allows one feedback per user' do
      user = create(:user)
      create(:feedback, user:)

      duplicate = build(:feedback, user:)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:base]).to include(I18n.t('feedback.errors.already_exists'))
    end

    it 'lets an existing feedback be updated' do
      saved = create(:feedback)

      expect(saved.update(rating: 3)).to be(true)
    end
  end

  describe 'sentiment' do
    {
      1 => :negative, 4 => :negative, 5 => :neutral, 6 => :neutral, 7 => :positive, 10 => :positive
    }.each do |rating, sentiment|
      it "maps rating #{rating} to #{sentiment}" do
        expect(build(:feedback, rating:).sentiment).to eq(sentiment)
      end
    end

    it 'filters by sentiment with .with_sentiment' do
      positive = create(:feedback, rating: 9)
      neutral  = create(:feedback, rating: 5)
      negative = create(:feedback, rating: 2)

      expect(described_class.with_sentiment(:positive)).to contain_exactly(positive)
      expect(described_class.with_sentiment(:neutral)).to contain_exactly(neutral)
      expect(described_class.with_sentiment(:negative)).to contain_exactly(negative)
    end
  end

  describe '#edited?' do
    it 'is false within the first hour and true once edited later' do
      saved = create(:feedback)
      expect(saved).not_to be_edited

      saved.update_columns(updated_at: saved.created_at + 30.minutes)
      expect(saved).not_to be_edited

      saved.update_columns(updated_at: saved.created_at + 2.hours)
      expect(saved).to be_edited
    end
  end

  describe 'replies' do
    it 'are ordered by posting time and removed with the feedback' do
      feedback = create(:feedback)
      late  = create(:feedback_reply, feedback:, created_at: 1.hour.ago)
      early = create(:feedback_reply, feedback:, created_at: 2.hours.ago)

      expect(feedback.reload.replies).to eq([ early, late ])
      expect { feedback.destroy }.to change(FeedbackReply, :count).by(-2)
    end
  end

  describe 'unread replies' do
    let(:feedback) { create(:feedback) }
    let(:admin)    { create(:user, :admin) }

    it 'counts only replies by others while nothing was seen' do
      unread = create(:feedback_reply, feedback:, user: admin)
      create(:feedback_reply, feedback:, user: feedback.user)

      expect(feedback.unread_replies).to contain_exactly(unread)
    end

    it 'counts only replies newer than replies_seen_at' do
      create(:feedback_reply, feedback:, user: admin, created_at: 3.hours.ago)
      newer = create(:feedback_reply, feedback:, user: admin, created_at: 1.hour.ago)
      feedback.update_column(:replies_seen_at, 2.hours.ago)

      expect(feedback.unread_replies).to contain_exactly(newer)
    end

    describe '#read_new_replies!' do
      it 'returns the new reply ids, ignoring the author\'s own replies' do
        first  = create(:feedback_reply, feedback:, user: admin, created_at: 2.hours.ago)
        second = create(:feedback_reply, feedback:, user: admin, created_at: 1.hour.ago)
        create(:feedback_reply, feedback:, user: feedback.user)

        expect(feedback.read_new_replies!).to contain_exactly(first.id, second.id)
      end

      it 'moves replies_seen_at to the newest read reply, not to now' do
        newest = create(:feedback_reply, feedback:, user: admin, created_at: 1.hour.ago)
        create(:feedback_reply, feedback:, user: admin, created_at: 2.hours.ago)

        feedback.read_new_replies!

        expect(feedback.reload.replies_seen_at).to be_within(1.second).of(newest.created_at)
        expect(feedback.replies_seen_at).to be < 30.minutes.ago
      end

      it 'returns nothing the second time' do
        create(:feedback_reply, feedback:, user: admin)
        feedback.read_new_replies!

        expect(feedback.read_new_replies!).to eq([])
      end

      it 'leaves a reply that arrives afterwards unread' do
        create(:feedback_reply, feedback:, user: admin, created_at: 1.hour.ago)
        feedback.read_new_replies!
        late = create(:feedback_reply, feedback:, user: admin)

        expect(feedback.read_new_replies!).to eq([ late.id ])
      end

      it 'keeps replies_seen_at nil and returns [] when there is nothing new' do
        expect(feedback.read_new_replies!).to eq([])
        expect(feedback.reload.replies_seen_at).to be_nil
      end
    end
  end
end
