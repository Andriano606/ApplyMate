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
end
