# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::ConfirmManualSubmit, type: :operation do
  include_context 'honeytech dou'

  let(:current_user) { user }
  let(:params)       { { id: apply.hashid } }

  before { apply.update!(status: :needs_review, error: 'gave up') }

  it 'marks the apply as completed' do
    expect(result).to be_success
    reloaded = apply.reload
    expect(reloaded.status).to eq('completed')
    expect(reloaded.error).to be_nil
  end

  it 'clears the open questions it was waiting on' do
    apply.update!(review_fields: [ { 'name' => 'x' } ])
    expect(result).to be_success
    expect(apply.reload.review_fields).to be_blank
  end

  context 'when the apply belongs to another user' do
    let(:current_user) do
      User.create!(email: 'other@example.com', name: 'Other', provider: 'google_oauth2', uid: 'uid-other-3')
    end

    it 'denies access' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
