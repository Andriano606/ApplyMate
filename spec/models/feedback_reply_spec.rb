# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedbackReply do
  subject(:reply) { build(:feedback_reply) }

  it { is_expected.to be_valid }

  it 'requires a body of at most 2000 characters' do
    reply.body = ''
    expect(reply).not_to be_valid

    reply.body = 'a' * 2001
    expect(reply).not_to be_valid

    reply.body = 'a' * 2000
    expect(reply).to be_valid
  end

  it 'requires a feedback and a user' do
    expect(build(:feedback_reply, feedback: nil)).not_to be_valid
    expect(build(:feedback_reply, user: nil)).not_to be_valid
  end

  describe '#role' do
    let(:feedback) { create(:feedback) }

    it 'is :admin for an admin, even under their own review' do
      expect(build(:feedback_reply, feedback:, user: create(:user, :admin)).role).to eq(:admin)
      own = create(:feedback, user: create(:user, :admin))
      expect(build(:feedback_reply, feedback: own, user: own.user).role).to eq(:admin)
    end

    it 'is :author for the feedback author' do
      expect(build(:feedback_reply, feedback:, user: feedback.user).role).to eq(:author)
    end

    it 'is nil for a demoted admin (neither admin nor author)' do
      former_admin = create(:user, :admin)
      reply = create(:feedback_reply, feedback:, user: former_admin)
      former_admin.update!(admin: false)

      expect(reply.reload.role).to be_nil
    end
  end

  describe 'thread cap' do
    let(:feedback) { create(:feedback) }

    before { stub_const('FeedbackReply::MAX_PER_FEEDBACK', 3) }

    it 'accepts replies up to the limit and rejects the next with a base error' do
      create_list(:feedback_reply, 3, feedback:)

      extra = build(:feedback_reply, feedback:)

      expect(extra).not_to be_valid
      expect(extra.errors[:base]).to include(I18n.t('feedback_reply.errors.thread_full', count: 3))
    end

    it 'does not count other threads' do
      create_list(:feedback_reply, 3, feedback: create(:feedback))

      expect(build(:feedback_reply, feedback:)).to be_valid
    end

    it 'does not block editing an existing reply' do
      replies = create_list(:feedback_reply, 3, feedback:)

      expect(replies.first.update(body: 'edited')).to be(true)
    end
  end
end
