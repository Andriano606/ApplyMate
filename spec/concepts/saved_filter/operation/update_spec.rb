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

  it "resets the view snapshot because it described the old state" do
    saved_filter.record_view!(count: 5, max_vacancy_id: 100)

    expect(result).to be_success
    expect(saved_filter.reload.last_seen_count).to be_nil
    expect(saved_filter.last_seen_max_vacancy_id).to be_nil
  end

  context "when only the name changes" do
    let(:params) do
      ActionController::Parameters.new(
        id: saved_filter.hashid,
        saved_filter: { name: 'Renamed',
                        include_tags: saved_filter.include_tags,
                        include_ops: saved_filter.include_ops,
                        exclude_tags: saved_filter.exclude_tags }
      )
    end

    it "keeps the view snapshot" do
      saved_filter.record_view!(count: 5, max_vacancy_id: 100)

      expect(result).to be_success
      expect(saved_filter.reload.name).to eq('Renamed')
      expect(saved_filter.last_seen_count).to eq(5)
    end
  end

  # "Зберегти в «name»" saves in one click: no modal, so no nested saved_filter
  context "when saved straight from the search bar link" do
    let(:params) do
      ActionController::Parameters.new(id: saved_filter.hashid,
                                       include_tags: %w[embedded remote],
                                       include_ops:  %w[g_or],
                                       exclude_tags: %w[junior])
    end

    it "overwrites the state and keeps the name" do
      expect(result).to be_success
      expect(saved_filter.reload.name).to eq('Embedded')
      expect(saved_filter.include_tags).to eq(%w[embedded remote])
      expect(saved_filter.include_ops).to eq(%w[g_or])
      expect(saved_filter.exclude_tags).to eq(%w[junior])
    end
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
