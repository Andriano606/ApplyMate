# frozen_string_literal: true

require 'rails_helper'

RSpec.describe McpConnection::Operation::Update, type: :operation do
  let(:current_user) { create(:user) }

  context 'when the user has a personal token' do
    let!(:personal) { create(:api_token, user: current_user, personal: true, last_used_at: 1.day.ago) }

    it 'regenerates the value and resets last use on the same record' do
      old_value = personal.token

      expect(result).to be_success
      expect(model.api_token).to eq(personal)
      expect(personal.reload.token).not_to eq(old_value)
      expect(personal.last_used_at).to be_nil
      expect(ApiToken.find_by(token: old_value)).to be_nil
    end

    it 'sets a notice' do
      expect(result.notice[:text]).to eq(I18n.t('mcp_connection.update.success'))
    end

    it 'does not add a token' do
      expect { result }.not_to change(ApiToken, :count)
    end
  end

  context 'when the user has no personal token yet' do
    it 'creates one' do
      expect { result }.to change { current_user.api_tokens.where(personal: true).count }.from(0).to(1)
      expect(model.api_token.token).to be_present
    end
  end

  context 'with an admin-issued token' do
    let!(:admin_issued) { create(:api_token, user: current_user) }

    it 'does not touch it' do
      expect { result }.not_to(change { admin_issued.reload.token })
    end
  end

  context 'for a guest' do
    let(:current_user) { nil }

    it 'is not authorized' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
