# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::PruneApplySteps do
  let(:apply) { create(:apply) }

  def step(key, finished_at:)
    ApplyStep.create!(apply:, attempt: 1, key:, stage: key, position: 0, state: :succeeded, started_at: 200.days.ago,
                      finished_at:)
  end

  it 'deletes steps finished more than 180 days ago and keeps the rest' do
    old = step('old', finished_at: 181.days.ago)
    recent = step('recent', finished_at: 179.days.ago)
    running = step('running', finished_at: nil)

    expect(described_class.call.model).to eq(1)

    expect(ApplyStep.exists?(old.id)).to be(false)
    expect(ApplyStep.exists?(recent.id)).to be(true)
    expect(ApplyStep.exists?(running.id)).to be(true)
  end

  it 'deletes in bounded batches' do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    stub_const("#{described_class}::MAX_BATCHES", 2)
    5.times { |i| step("old#{i}", finished_at: 200.days.ago) }

    expect(described_class.call.model).to eq(4)
    expect(ApplyStep.count).to eq(1)
  end

  it 'never deletes applies' do
    step('old', finished_at: 181.days.ago)

    expect { described_class.call }.not_to change(Apply, :count)
  end
end
