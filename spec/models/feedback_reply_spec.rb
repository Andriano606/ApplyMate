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

  describe '.unread_for' do
    let(:author)   { create(:user) }
    let(:admin)    { create(:user, :admin) }
    let(:feedback) { create(:feedback, user: author) }

    it 'gives the author replies by others while they have no read mark' do
      reply = create(:feedback_reply, feedback:, user: admin)

      expect(described_class.unread_for(author)).to contain_exactly(reply)
    end

    it 'excludes the user\'s own replies' do
      create(:feedback_reply, feedback:, user: author)

      expect(described_class.unread_for(author)).to be_empty
    end

    it 'excludes threads the user does not take part in' do
      create(:feedback_reply, feedback:, user: admin)

      expect(described_class.unread_for(create(:user))).to be_empty
      expect(described_class.unread_for(create(:user, :admin))).to be_empty
    end

    it 'gives a replier (read mark) the author\'s later answers only' do
      create(:feedback_reply, feedback:, user: admin, created_at: 3.hours.ago)
      FeedbackThreadRead.mark_seen!(admin, { feedback.id => 2.hours.ago })
      answer = create(:feedback_reply, feedback:, user: author, created_at: 1.hour.ago)

      expect(described_class.unread_for(admin)).to contain_exactly(answer)
    end

    it 'only counts replies newer than the read mark' do
      create(:feedback_reply, feedback:, user: admin, created_at: 3.hours.ago)
      newer = create(:feedback_reply, feedback:, user: admin, created_at: 1.hour.ago)
      FeedbackThreadRead.mark_seen!(author, { feedback.id => 2.hours.ago })

      expect(described_class.unread_for(author)).to contain_exactly(newer)
    end

    it 'does not leak other users\' marks' do
      reply = create(:feedback_reply, feedback:, user: admin)
      FeedbackThreadRead.mark_seen!(create(:user), { feedback.id => 1.minute.from_now })

      expect(described_class.unread_for(author)).to contain_exactly(reply)
    end
  end

  describe '.read_unread!' do
    let(:author)   { create(:user) }
    let(:admin)    { create(:user, :admin) }
    let(:feedback) { create(:feedback, user: author) }

    it 'returns the new reply ids and reads them' do
      first  = create(:feedback_reply, feedback:, user: admin, created_at: 2.hours.ago)
      second = create(:feedback_reply, feedback:, user: admin, created_at: 1.hour.ago)

      expect(described_class.read_unread!(author, [ feedback.id ])).to contain_exactly(first.id, second.id)
      expect(described_class.read_unread!(author, [ feedback.id ])).to eq([])
    end

    it 'moves the mark to the newest read reply, not to now, so a later reply stays unread' do
      newest = create(:feedback_reply, feedback:, user: admin, created_at: 1.hour.ago)
      described_class.read_unread!(author, [ feedback.id ])
      mark = FeedbackThreadRead.find_by!(user: author, feedback:)

      expect(mark.seen_at).to be_within(1.second).of(newest.created_at)
      late = create(:feedback_reply, feedback:, user: admin)
      expect(described_class.read_unread!(author, [ feedback.id ])).to eq([ late.id ])
    end

    it 'only reads the requested threads' do
      other = create(:feedback, user: create(:user))
      create(:feedback_reply, feedback: other, user: admin)
      create(:feedback_reply, feedback:, user: admin)
      FeedbackThreadRead.mark_seen!(author, { other.id => 1.day.ago }) # participates in both

      described_class.read_unread!(author, [ feedback.id ])

      expect(described_class.unread_for(author).pluck(:feedback_id)).to eq([ other.id ])
    end

    it 'never moves a mark backwards when marked twice with an older time' do
      reply = create(:feedback_reply, feedback:, user: admin, created_at: 1.hour.ago)
      described_class.read_unread!(author, [ feedback.id ])
      FeedbackThreadRead.mark_seen!(author, { feedback.id => 5.hours.ago })

      expect(FeedbackThreadRead.find_by!(user: author, feedback:).seen_at).to be_within(1.second).of(reply.created_at)
    end

    it 'does nothing for a guest or an empty list' do
      create(:feedback_reply, feedback:, user: admin)

      expect(described_class.read_unread!(nil, [ feedback.id ])).to eq([])
      expect(described_class.read_unread!(author, [])).to eq([])
    end
  end
end
