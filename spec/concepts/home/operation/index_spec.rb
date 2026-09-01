# frozen_string_literal: true

require "rails_helper"

RSpec.describe Home::Operation::Index, type: :operation do
  include_context "with elasticsearch index"

  it "returns a successful result" do
    expect(result).to be_success
  end

  it "marks authorization as skipped" do
    expect(result[:pundit]).to be true
  end

  context "when the user has a default saved filter" do
    let(:current_user) { create(:user) }
    let(:saved_filter) do
      create(:saved_filter, user: current_user,
                            include_tags: %w[embedded stm32], include_ops: %w[and], exclude_tags: %w[junior])
    end

    before { current_user.update!(default_saved_filter: saved_filter) }

    it "applies the default preset on a bare visit" do
      expect(result).to be_success
      expect(model.include_tags).to eq(%w[embedded stm32])
      expect(model.include_ops).to eq(%w[and])
      expect(model.exclude_tags).to eq(%w[junior])
      expect(model.saved_filter).to eq(saved_filter)
    end

    context "when explicit search params are given" do
      let(:params) { { include_tags: [ 'ruby' ] } }

      it "keeps the explicit search instead of the preset" do
        expect(result).to be_success
        expect(model.include_tags).to eq(%w[ruby])
        expect(model.exclude_tags).to be_nil
        expect(model.saved_filter).to be_nil
      end
    end
  end

  context "when the user has no default saved filter" do
    let(:current_user) { create(:user) }

    it "applies no filter" do
      expect(result).to be_success
      expect(model.include_tags).to be_nil
    end
  end
end
