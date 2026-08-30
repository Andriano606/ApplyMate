# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedFilter::Operation::Create, type: :operation do
  let(:current_user) { create(:user) }
  let(:params) do
    ActionController::Parameters.new(
      saved_filter: { name: 'Embedded remote',
                      include_tags: [ 'embedded', 'stm32', 'remote', 'віддалено' ],
                      include_ops: [ 'and', 'and', 'g_or' ],
                      exclude_tags: [ 'junior' ] }
    )
  end

  it "saves the filter with the search state" do
    expect(result).to be_success
    expect(model).to be_persisted
    expect(model.name).to eq('Embedded remote')
    expect(model.include_tags).to eq(%w[embedded stm32 remote віддалено])
    expect(model.include_ops).to eq(%w[and and g_or])
    expect(model.exclude_tags).to eq(%w[junior])
    expect(model.user).to eq(current_user)
  end

  it "becomes the user's default preset" do
    expect(result).to be_success
    expect(current_user.reload.default_saved_filter).to eq(model)
  end

  context "when name is blank" do
    let(:params) { ActionController::Parameters.new(saved_filter: { name: '' }) }

    it "fails with a validation error" do
      expect(result).to be_failure
      expect(result.errors[:name]).to be_present
    end
  end

  context "when the user already has a filter with the same name" do
    before { create(:saved_filter, user: current_user, name: 'Embedded remote') }

    it "fails with a uniqueness error" do
      expect(result).to be_failure
      expect(result.errors[:name]).to be_present
    end
  end

  context "when another user has a filter with the same name" do
    before { create(:saved_filter, name: 'Embedded remote') }

    it "saves the filter" do
      expect(result).to be_success
    end
  end
end
