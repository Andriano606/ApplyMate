# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Feedback::Operation::Destroy, type: :operation do
  let!(:feedback)    { create(:feedback) }
  let(:current_user) { feedback.user }
  let(:params)       { ActionController::Parameters.new(id: feedback.to_param) }

  before do
    create(:feedback_reply, feedback:)
    FeedbackThreadRead.mark_seen!(create(:user), { feedback.id => Time.current })
  end

  it 'lets the author delete their feedback with the thread and read marks' do
    expect(result).to be_success
    expect(Feedback.exists?(feedback.id)).to be(false)
    expect(FeedbackReply.count).to eq(0)
    expect(FeedbackThreadRead.count).to eq(0)
    expect(result.notice[:text]).to eq(I18n.t('feedback.destroy.success'))
  end

  it 'lets the author post a new feedback afterwards' do
    result

    created = Feedback::Operation::Create.call(
      params: ActionController::Parameters.new(feedback: { rating: '7', body: 'Round two' }), current_user:
    )

    expect(created).to be_success
  end

  context 'when an admin moderates' do
    let(:current_user) { create(:user, :admin) }

    it 'deletes someone else\'s feedback' do
      expect(result).to be_success
      expect(Feedback.exists?(feedback.id)).to be(false)
    end
  end

  context 'when another regular user tries' do
    let(:current_user) { create(:user) }

    it 'is not authorized and deletes nothing' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
      expect(Feedback.exists?(feedback.id)).to be(true)
      expect(FeedbackReply.count).to eq(1)
    end
  end

  context 'when nobody is signed in' do
    let(:current_user) { nil }

    it 'is not authorized' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  context 'with an unknown id' do
    let(:params) { ActionController::Parameters.new(id: 'nope') }

    it 'raises RecordNotFound' do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
