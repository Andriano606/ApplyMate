# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedbackReply::Operation::Create, type: :operation do
  let(:feedback)     { create(:feedback) }
  let(:current_user) { create(:user, :admin) }
  let(:body)         { 'Thank you, we are on it' }
  let(:params) do
    ActionController::Parameters.new(feedback_id: feedback.id, feedback_reply: { body: })
  end

  it 'lets an admin reply under any review' do
    expect(result).to be_success
    expect(feedback.replies.reload.map { |r| [ r.user, r.body ] }).to eq([ [ current_user, body ] ])
    expect(result.notice[:text]).to eq(I18n.t('feedback_reply.create.success'))
  end

  context 'when the author answers in their own thread' do
    let(:current_user) { feedback.user }

    it 'creates the reply' do
      expect(result).to be_success
      expect(model).to be_persisted
      expect(model.role).to eq(:author)
    end
  end

  context 'when another regular user replies' do
    let(:current_user) { create(:user) }

    it 'is not authorized and stores nothing' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
      expect(FeedbackReply.count).to eq(0)
    end
  end

  context 'when nobody is signed in' do
    let(:current_user) { nil }

    it 'is not authorized' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  context 'with a blank body' do
    let(:body) { ' ' }

    it 'fails with a body error' do
      expect(result).to be_failure
      expect(result.errors[:body]).to be_present
      expect(FeedbackReply.count).to eq(0)
    end
  end

  context 'with a body over the limit' do
    let(:body) { 'a' * (FeedbackReply::BODY_MAX_LENGTH + 1) }

    it 'fails with a body error' do
      expect(result).to be_failure
      expect(result.errors[:body]).to be_present
    end
  end

  context 'with an unknown feedback' do
    let(:params) { ActionController::Parameters.new(feedback_id: 0, feedback_reply: { body: }) }

    it 'raises RecordNotFound' do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it 'leaves a read mark for the replier at the reply time' do
    expect { result }.to change { FeedbackThreadRead.where(user: current_user, feedback:).count }.from(0).to(1)

    expect(FeedbackThreadRead.find_by!(user: current_user, feedback:).seen_at).to be_within(1.second).of(model.created_at)
  end

  it 'does not make the replier\'s own reply unread for them' do
    result

    expect(current_user.unread_feedback_reply_count).to eq(0)
  end

  it 'notifies the admin once the author answers, and not before' do
    result
    expect(current_user.unread_feedback_reply_count).to eq(0)

    described_class.call(params: ActionController::Parameters.new(feedback_id: feedback.id, feedback_reply: { body: 'Thanks' }),
                         current_user: feedback.user)

    expect(current_user.unread_feedback_reply_count).to eq(1)
    expect(feedback.user.unread_feedback_reply_count).to eq(0) # answering reads the thread for the author
  end

  it 'leaves no mark when the reply is invalid' do
    invalid = described_class.call(params: ActionController::Parameters.new(feedback_id: feedback.id, feedback_reply: { body: '' }),
                                   current_user:)

    expect(invalid).to be_failure
    expect(FeedbackThreadRead.count).to eq(0)
  end
end
