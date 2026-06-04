# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ApiToken::Operation::Create, type: :operation do
  let(:current_user) { create(:user, :admin) }
  let(:target)       { create(:user) }
  let(:params) do
    ActionController::Parameters.new(api_token: { user_id: target.id, name: 'CI token' })
  end

  it 'marks authorization as performed' do
    expect(result[:pundit]).to be true
  end

  it 'creates a token mapped to the selected user' do
    expect { result }.to change(ApiToken, :count).by(1)
    expect(result.model.user).to eq(target)
    expect(result.model.name).to eq('CI token')
  end

  it 'generates a token value' do
    expect(result.model.token).to be_present
  end
end
