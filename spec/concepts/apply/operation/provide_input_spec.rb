# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::ProvideInput, type: :operation do
  include_context 'with shared operation spec variables'

  let(:current_user) { create(:user) }
  let(:apply) do
    create(:apply, :running, user: current_user, stage: 'awaiting_input',
                             input_request: { 'kind' => 'email_code', 'expires_at' => 5.minutes.from_now.iso8601 })
  end
  let(:code) { SecureRandom.random_number(1_000_000).to_s.rjust(6, '0') }
  let(:params) { { id: apply.hashid, code: } }

  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  it 'stores the trimmed code while the apply is running and waiting, and broadcasts' do
    op = described_class.new(params: { id: apply.hashid, code: " #{code} " }, current_user:)
    op.call

    expect(op.result).to be_success
    expect(apply.reload.input_response).to include('code' => code, 'at' => be_present)
    expect(op.result.notice[:text]).to eq(I18n.t('apply.provide_input.success'))
    expect(Apply::TurboHandler::StatusUpdate).to have_received(:broadcast).with(apply)
  end

  it 'changes nothing when the apply is not waiting for input' do
    apply.update_columns(stage: 'fill')

    expect(result.errors[:base]).to eq([ I18n.t('apply.provide_input.not_allowed') ])
    expect(apply.reload.input_response).to be_nil
  end

  it 'changes nothing once the request was cleared' do
    apply.update_columns(input_request: nil)

    expect(result.errors[:base]).to eq([ I18n.t('apply.provide_input.not_allowed') ])
  end

  it 'changes nothing when the apply is no longer running' do
    apply.update_columns(state: Apply.states[:needs_human])

    expect(result.errors[:base]).to eq([ I18n.t('apply.provide_input.not_allowed') ])
  end

  [ '', '   ', 'x' * (described_class::MAX_CODE_LENGTH + 1) ].each do |bad|
    it "rejects the code #{bad.inspect.truncate(20)}" do
      op = described_class.new(params: { id: apply.hashid, code: bad }, current_user:)
      op.call

      expect(op.result.errors[:base]).to eq([ I18n.t('apply.provide_input.invalid_code') ])
      expect(apply.reload.input_response).to be_nil
    end
  end

  it "does not reveal another user's apply" do
    foreign = create(:apply, :running, stage: 'awaiting_input', input_request: { 'kind' => 'email_code' })

    expect { described_class.call(params: { id: foreign.hashid, code: }, current_user:) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end
