# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedFilter::Operation::Update, type: :operation do
  let(:current_user) { create(:user) }
  let(:saved_filter) do
    create(:saved_filter, user: current_user, name: 'Embedded',
                          include_tags: %w[embedded], include_ops: [], exclude_tags: [])
  end
  let(:params) do
    ActionController::Parameters.new(
      id: saved_filter.hashid,
      saved_filter: { name: 'Embedded remote',
                      include_tags: %w[embedded remote віддалено],
                      include_ops: %w[and g_or],
                      exclude_tags: %w[junior] }
    )
  end

  it "renames the preset and overwrites its search state" do
    expect(result).to be_success
    expect(saved_filter.reload.name).to eq('Embedded remote')
    expect(saved_filter.include_tags).to eq(%w[embedded remote віддалено])
    expect(saved_filter.include_ops).to eq(%w[and g_or])
    expect(saved_filter.exclude_tags).to eq(%w[junior])
  end

  it "becomes the user's default preset" do
    expect(result).to be_success
    expect(current_user.reload.default_saved_filter).to eq(saved_filter)
  end

  context "when the new name is blank" do
    let(:params) do
      ActionController::Parameters.new(id: saved_filter.hashid, saved_filter: { name: '' })
    end

    it "fails and leaves the preset untouched" do
      expect(result).to be_failure
      expect(result.errors[:name]).to be_present
      expect(saved_filter.reload.name).to eq('Embedded')
    end
  end

  context "when another preset of the same user already has that name" do
    before { create(:saved_filter, user: current_user, name: 'Taken') }

    let(:params) do
      ActionController::Parameters.new(id: saved_filter.hashid, saved_filter: { name: 'Taken' })
    end

    it "fails with a uniqueness error" do
      expect(result).to be_failure
      expect(result.errors[:name]).to be_present
    end
  end

  context "when the preset belongs to another user" do
    let(:saved_filter) { create(:saved_filter) }

    it "raises RecordNotFound" do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
