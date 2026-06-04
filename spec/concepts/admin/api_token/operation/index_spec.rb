# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::ApiToken::Operation::Index, type: :operation do
  let(:current_user) { create(:user, :admin) }

  it 'marks authorization as performed' do
    expect(result[:pundit]).to be true
  end

  it 'returns the existing tokens' do
    token = create(:api_token)
    expect(result.model).to include(token)
  end

  context 'when the user is not an admin' do
    let(:current_user) { create(:user) }

    it 'raises a not authorized error' do
      expect { result }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
