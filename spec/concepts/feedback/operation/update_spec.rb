# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Feedback::Operation::Update, type: :operation do
  let(:current_user) { create(:user) }
  let!(:feedback)    { create(:feedback, user: current_user, rating: 4, body: 'Meh', posted_via: 'web') }
  let(:attributes)   { { rating: '9', body: 'Much better now' } }
  let(:params)       { ActionController::Parameters.new(id: feedback.to_param, feedback: attributes) }

  it 'replaces rating and text' do
    expect(result).to be_success
    expect(feedback.reload).to have_attributes(rating: 9, body: 'Much better now', posted_via: 'web')
    expect(result.notice[:text]).to eq(I18n.t('feedback.update.success'))
  end

  it 'records where the new version came from' do
    operation = described_class.new(params:, current_user:, posted_via: 'mcp').tap(&:call)

    expect(operation.result).to be_success
    expect(feedback.reload.posted_via).to eq('mcp')
  end

  it 'does not create a second feedback' do
    expect { result }.not_to change(Feedback, :count)
  end

  context 'with invalid attributes' do
    let(:attributes) { { rating: '0', body: 'x' } }

    it 'fails and leaves the feedback untouched' do
      expect(result).to be_failure
      expect(result.errors[:rating]).to be_present
      expect(feedback.reload).to have_attributes(rating: 4, body: 'Meh')
    end
  end

  context "when the feedback is somebody else's" do
    let(:feedback) { create(:feedback, rating: 4, body: 'Meh') }

    it 'is not authorized and changes nothing' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
      expect(feedback.reload.body).to eq('Meh')
    end
  end

  context 'when nobody is signed in' do
    let(:current_user) { nil }
    let(:feedback)     { create(:feedback, body: 'Meh') }

    it 'is not authorized' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
