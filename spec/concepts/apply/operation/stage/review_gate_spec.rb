# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::ReviewGate do
  let(:user) { create(:user) }
  let(:answers) { { 'a' => answer_entry('x', source: 'ai', confidence: 0.2) } }
  let(:apply) do
    create(:apply, user:, answers:, entry_url: 'https://dou.ua/goto/vacancy/?id=1', form_url: 'https://jobs.ashbyhq.com/p/1/application')
  end

  before { allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast) }

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to eq('Перевірка перед надсиланням')
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to eq('Review before submit')
  end

  it 'always runs' do
    expect(described_class.input_digest(engine_context(apply))).to be_nil
  end

  it 'stops in needs_review with the reasons in the failure' do
    run_engine_step(apply, described_class)

    expect(apply).to be_needs_review
    expect(apply.failure_code).to eq('review')
    expect(apply.failure_info[:detail]).to eq('low_confidence')
  end

  it 'passes when there is no reason to review' do
    apply.update!(answers: { 'a' => answer_entry('x', source: 'ai', confidence: 0.95) })
    ctx = engine_context(apply)

    expect { described_class.call(ctx:) }.not_to raise_error
    expect(described_class.call(ctx:)[:step_result]).to eq('reasons' => [])
  end

  it 'passes when the user approved exactly these answers' do
    apply.update!(answers_approved_digest: Apply::Operation::Answer::Digest.call(answers:).model)

    expect { described_class.call(ctx: engine_context(apply)) }.not_to raise_error
  end

  it 'stops again when the answers changed after the approval' do
    apply.update!(answers_approved_digest: Apply::Operation::Answer::Digest.call(answers:).model,
                  answers: { 'a' => answer_entry('other', source: 'ai', confidence: 0.2) })

    run_engine_step(apply, described_class)

    expect(apply).to be_needs_review
  end
end
