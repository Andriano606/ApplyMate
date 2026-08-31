# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedFilter::Operation::Edit, type: :operation do
  let(:current_user) { create(:user) }
  let(:saved_filter) do
    create(:saved_filter, user: current_user,
                          include_tags: %w[embedded stm32], include_ops: %w[and], exclude_tags: %w[junior])
  end
  let(:params) { ActionController::Parameters.new(id: saved_filter.hashid) }

  it "prefills the form with the stored preset when opened from the pill" do
    expect(result).to be_success
    expect(model.name).to eq(saved_filter.name)
    expect(model.include_tags).to eq(%w[embedded stm32])
    expect(model.exclude_tags).to eq(%w[junior])
  end

  context "when opened from the search bar with a modified state" do
    let(:params) do
      ActionController::Parameters.new(id: saved_filter.hashid,
                                       include_tags: %w[embedded stm32 remote],
                                       include_ops:  %w[and and],
                                       exclude_tags: [])
    end

    it "prefills the form with the state currently on screen" do
      expect(result).to be_success
      expect(model.include_tags).to eq(%w[embedded stm32 remote])
      expect(model.include_ops).to eq(%w[and and])
      expect(model.exclude_tags).to eq([])
    end

    it "does not persist anything yet" do
      expect(result).to be_success
      expect(saved_filter.reload.include_tags).to eq(%w[embedded stm32])
    end
  end

  context "when the preset belongs to another user" do
    let(:saved_filter) { create(:saved_filter) }

    it "raises RecordNotFound" do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
