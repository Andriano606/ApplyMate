# frozen_string_literal: true

require 'rails_helper'

RSpec.describe McpConnection::Operation::Create, type: :operation do
  let(:current_user) { create(:user) }

  it 'creates the personal token with the standard name' do
    expect { result }.to change { current_user.api_tokens.count }.by(1)

    expect(model.api_token).to have_attributes(personal: true, name: ApiToken::PERSONAL_NAME, user: current_user)
    expect(model.api_token.token).to be_present
  end

  it 'is idempotent: a second call returns the same token' do
    first = described_class.call(params: {}, current_user:).model.api_token
    second = described_class.call(params: {}, current_user:).model.api_token

    expect(second).to eq(first)
    expect(second.token).to eq(first.token)
    expect(current_user.api_tokens.where(personal: true).count).to eq(1)
  end

  it 'leaves admin-issued tokens alone' do
    admin_issued = create(:api_token, user: current_user)

    expect(model.api_token).not_to eq(admin_issued)
    expect(admin_issued.reload).to have_attributes(personal: false, name: 'Test token')
  end

  it 'gives every user their own token' do
    other = described_class.call(params: {}, current_user: create(:user)).model.api_token

    expect(other).not_to eq(model.api_token)
  end

  context 'for a guest' do
    let(:current_user) { nil }

    it 'is not authorized' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
