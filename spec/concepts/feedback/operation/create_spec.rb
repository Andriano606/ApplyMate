# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Feedback::Operation::Create, type: :operation do
  let(:current_user) { create(:user) }
  let(:attributes)   { { rating: '9', body: 'Great vacancy bank' } }
  let(:params)       { ActionController::Parameters.new(feedback: attributes) }

  it 'publishes the feedback for the user as a web post' do
    expect(result).to be_success
    expect(model).to be_persisted
    expect(current_user.reload.feedback).to have_attributes(rating: 9, body: 'Great vacancy bank', posted_via: 'web')
    expect(result.notice[:text]).to eq(I18n.t('feedback.create.success'))
  end

  it 'records a trusted posted_via' do
    operation = described_class.new(params:, current_user:, posted_via: 'mcp').tap(&:call)

    expect(operation.result).to be_success
    expect(current_user.reload.feedback.posted_via).to eq('mcp')
  end

  it 'ignores posted_via smuggled through params' do
    smuggled = ActionController::Parameters.new(feedback: attributes.merge(posted_via: 'mcp', user_id: create(:user).id))

    described_class.new(params: smuggled, current_user:).tap(&:call)

    expect(current_user.reload.feedback).to have_attributes(posted_via: 'web', user_id: current_user.id)
  end

  context 'when nobody is signed in' do
    let(:current_user) { nil }

    it 'is not authorized' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end

  context 'with invalid attributes' do
    let(:attributes) { { rating: '11', body: '' } }

    it 'fails with field errors and stores nothing' do
      expect(result).to be_failure
      expect(result.errors[:rating]).to be_present
      expect(result.errors[:body]).to be_present
      expect(Feedback.count).to eq(0)
    end
  end

  context 'when the user already has a feedback' do
    before { create(:feedback, user: current_user, body: 'First') }

    it 'fails with a base error and keeps the original' do
      expect(result).to be_failure
      expect(result.errors[:base]).to include(I18n.t('feedback.errors.already_exists'))
      expect(current_user.reload.feedback.body).to eq('First')
    end
  end

  context 'when a concurrent post wins the race past the validation' do
    before do
      allow(Feedback).to receive(:exists?).and_return(false)
      create(:feedback, user: current_user, body: 'First')
    end

    it 'turns RecordNotUnique into the same base error' do
      expect(result).to be_failure
      expect(result.errors[:base]).to include(I18n.t('feedback.errors.already_exists'))
      expect(Feedback.where(user: current_user).count).to eq(1)
    end
  end
end
