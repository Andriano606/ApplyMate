# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedFilter::Operation::New, type: :operation do
  let(:current_user) { create(:user) }
  let(:params) do
    ActionController::Parameters.new(
      include_tags: [ 'embedded', 'remote', 'віддалено' ],
      include_ops:  [ 'and', 'g_or' ],
      exclude_tags: [ 'junior' ]
    )
  end

  it "prefills an unsaved filter with the current search state" do
    expect(result).to be_success
    expect(model).to be_new_record
    expect(model.include_tags).to eq(%w[embedded remote віддалено])
    expect(model.include_ops).to eq(%w[and g_or])
    expect(model.exclude_tags).to eq(%w[junior])
  end

  context "when the search is empty" do
    let(:params) { ActionController::Parameters.new({}) }

    it "builds a filter with empty arrays" do
      expect(result).to be_success
      expect(model.include_tags).to eq([])
      expect(model.exclude_tags).to eq([])
    end
  end
end
