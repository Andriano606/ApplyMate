# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Lifecycle::HaltUnowned do
  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  def halt(apply, code = :unexpected_error, detail: 'RuntimeError')
    described_class.call(apply_id: apply.id, code:, detail:).model
  end

  %i[queued waiting_capacity].each do |state|
    it "records the halt on a #{state} apply" do
      apply = create(:apply, state:)

      expect(halt(apply)).to be(true)
      apply.reload
      expect(apply).to be_failed
      expect(apply.failure).to include('code' => 'unexpected_error', 'kind' => 'permanent', 'detail' => 'RuntimeError',
                                       'after_claim' => false)
      expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast)
    end
  end

  it 'maps the code to its state' do
    apply = create(:apply)
    halt(apply, :no_application_path)

    expect(apply.reload).to be_unsupported
  end

  it 'never touches a running apply' do
    apply = create(:apply, :running)

    expect(halt(apply)).to be(false)
    expect(apply.reload).to be_running
    expect(apply.failure).to be_nil
    expect(Apply::TurboHandler::StatusUpdate).not_to have_received(:broadcast)
  end

  it 'ignores finished applies' do
    apply = create(:apply, :completed)

    expect(halt(apply)).to be(false)
    expect(apply.reload).to be_completed
  end

  it 'returns false for a missing apply' do
    expect(described_class.call(apply_id: 0, code: :unexpected_error).model).to be(false)
  end
end
