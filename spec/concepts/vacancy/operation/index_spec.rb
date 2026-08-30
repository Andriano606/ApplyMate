# frozen_string_literal: true

require "rails_helper"

RSpec.describe Vacancy::Operation::Index, type: :operation do
  include_context "with elasticsearch index"

  # Real requests deliver ActionController::Parameters, not a Hash — keep specs
  # on the production code path (Parameters lacks Hash methods like sort_by)
  let(:params) { ActionController::Parameters.new(raw_params) }

  context "when only a new tag is typed into the search field" do
    let(:raw_params) { { new_include_tag: 'stm32' } }

    it "adds the tag with a default op" do
      expect(result).to be_success
      expect(model.include_tags).to eq(%w[stm32])
      expect(model.include_ops).to eq(%w[or])
    end
  end

  context "when op toggles submit three-state values" do
    let(:raw_params) do
      { include_tags: [ 'embedded', 'stm32', 'remote', 'віддалено' ],
        include_ops:  { '0' => 'and', '1' => 'and', '2' => 'g_or' } }
    end

    it "keeps and/or/g_or values in submitted order" do
      expect(result).to be_success
      expect(model.include_ops).to eq(%w[and and g_or])
    end
  end

  context "when legacy checkbox op params are submitted" do
    let(:raw_params) do
      { include_tags: [ 'ruby', 'rails', 'react' ],
        include_ops:  { '0' => '1', '1' => '0' } }
    end

    it "maps boolean-ish values to and/or" do
      expect(result).to be_success
      expect(model.include_ops).to eq(%w[and or])
    end
  end

  context "when a saved-filter pill is clicked (saved_filter_id param)" do
    let(:current_user) { create(:user) }
    let(:saved_filter) { create(:saved_filter, user: current_user) }
    let(:raw_params) do
      { saved_filter_id: saved_filter.hashid,
        include_tags: saved_filter.include_tags,
        include_ops:  saved_filter.include_ops,
        exclude_tags: saved_filter.exclude_tags }
    end

    it "remembers the filter as the user's default preset" do
      expect(result).to be_success
      expect(current_user.reload.default_saved_filter).to eq(saved_filter)
    end

    context "when the filter belongs to another user" do
      let(:saved_filter) { create(:saved_filter) }

      it "does not change the default preset" do
        expect(result).to be_success
        expect(current_user.reload.default_saved_filter).to be_nil
      end
    end
  end

  context "when deleting a pill that belongs to an explicit OR group" do
    let(:raw_params) do
      { include_tags: [ 'embedded', 'remote', 'віддалено' ],
        include_ops:  { '0' => 'and', '1' => 'g_or' },
        include_delete_tag: { '0' => '0', '1' => '1', '2' => '0' } }
    end

    it "drops the group op and keeps the outer one" do
      expect(result).to be_success
      expect(model.include_tags).to eq(%w[embedded віддалено])
      expect(model.include_ops).to eq(%w[and])
    end
  end
end
