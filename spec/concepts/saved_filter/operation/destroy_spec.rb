# frozen_string_literal: true

require "rails_helper"

RSpec.describe SavedFilter::Operation::Destroy, type: :operation do
  let(:current_user) { create(:user) }
  let(:saved_filter) { create(:saved_filter, user: current_user) }
  let(:params) { { id: saved_filter.hashid } }

  it "destroys the user's filter" do
    expect(result).to be_success
    expect(SavedFilter.exists?(saved_filter.id)).to be(false)
  end

  context "when the filter belongs to another user" do
    let(:saved_filter) { create(:saved_filter) }

    it "raises RecordNotFound" do
      expect { result }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
