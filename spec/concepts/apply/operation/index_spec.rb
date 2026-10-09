# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Index, type: :operation do
  include_context 'with shared operation spec variables'

  let(:current_user) { create(:user) }
  let!(:queued)      { create(:apply, user: current_user, created_at: 3.hours.ago) }
  let!(:failed)      { create(:apply, :failed, user: current_user, created_at: 2.hours.ago) }
  let!(:needs_human) { create(:apply, :needs_human, user: current_user, created_at: 1.hour.ago) }

  before do
    create(:apply, :failed)
    Rails.cache.clear
  end

  it 'lists all own applies newest first without a filter' do
    expect(result).to be_success
    expect(model.applies).to respond_to(:total_pages)
    expect(model.applies.to_a).to eq([ needs_human, failed, queued ])
    expect(model.filter).to be_nil
    expect(model.attention_count).to eq(2)
  end

  context 'with the attention filter' do
    let(:params) { { filter: 'attention' } }

    it 'returns only attention states' do
      expect(model.applies.to_a).to eq([ needs_human, failed ])
      expect(model.filter).to eq('attention')
      expect(model.attention_count).to eq(2)
    end
  end

  context 'with an unknown filter' do
    let(:params) { { filter: 'DROP' } }

    it 'ignores it' do
      expect(model.filter).to be_nil
      expect(model.applies.size).to eq(3)
    end
  end
end
