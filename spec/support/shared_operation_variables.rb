# frozen_string_literal: true

RSpec.shared_context "with shared operation spec variables" do
  let(:operation) { described_class.new(params:, current_user:) }
  let(:result) { operation.tap(&:call).result }
  let(:model) { result.model }
  let(:params) { {} }
  let(:current_user) { nil }
end
