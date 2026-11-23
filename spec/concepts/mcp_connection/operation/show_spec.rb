# frozen_string_literal: true

require 'rails_helper'

RSpec.describe McpConnection::Operation::Show, type: :operation do
  let(:current_user) { create(:user) }

  it 'reports no token and never creates one' do
    expect(result).to be_success
    expect(model.api_token).to be_nil
    expect { result }.not_to change(ApiToken, :count)
  end

  context 'when the user has a personal token' do
    let!(:personal) { create(:api_token, user: current_user, personal: true) }

    it 'returns it' do
      expect(model.api_token).to eq(personal)
    end
  end

  context 'when the user only has an admin-issued token' do
    before { create(:api_token, user: current_user) }

    it 'does not treat it as the personal one' do
      expect(model.api_token).to be_nil
    end
  end

  context 'for a guest' do
    let(:current_user) { nil }

    it 'is not authorized' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
