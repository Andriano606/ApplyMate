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

  describe 'artifacts' do
    def attach(step)
      step.artifacts.attach(io: StringIO.new('png'), filename: 'shot.png', content_type: 'image/png')
    end

    it 'purges artifacts of steps older than 30 days and keeps newer ones' do
      old = step('old', finished_at: 40.days.ago)
      recent = step('recent', finished_at: 5.days.ago)
      attach(old)
      attach(recent)

      expect { described_class.call }.to have_enqueued_job(ActiveStorage::PurgeJob).once
      expect(recent.artifacts).to be_attached
    end

    it 'purges the attachments of the rows it deletes before deleting them' do
      doomed = step('doomed', finished_at: 200.days.ago)
      attach(doomed)

      expect { described_class.call }.to have_enqueued_job(ActiveStorage::PurgeJob).at_least(:once)
      expect(ApplyStep.exists?(doomed.id)).to be(false)
    end
  end

  describe 'traces' do
    it 'nulls traces older than 90 days and keeps the rows and newer traces' do
      old = step('old', finished_at: 100.days.ago)
      recent = step('recent', finished_at: 10.days.ago)
      untraced = step('untraced', finished_at: 100.days.ago)
      [ old, recent ].each { |row| row.update_columns(trace: [ { 'op' => 'goto' } ]) }

      expect(described_class.call.model).to eq(0)

      expect(old.reload.trace).to be_nil
      expect(recent.reload.trace).to eq([ { 'op' => 'goto' } ])
      expect(untraced.reload.trace).to be_nil
    end

    it 'nulls in bounded batches' do
      stub_const("#{described_class}::BATCH_SIZE", 2)
      stub_const("#{described_class}::MAX_BATCHES", 2)
      rows = Array.new(5) { |i| step("t#{i}", finished_at: 100.days.ago) }
      rows.each { |row| row.update_columns(trace: [ 1 ]) }

      described_class.call

      expect(ApplyStep.where.not(trace: nil).count).to eq(1)
    end
  end

  describe 'host slots' do
    it 'deletes slots idle for more than a day' do
      ApplyHostSlot.create!(host_key: 'stale.example', next_allowed_at: 2.days.ago, holder_apply_id: 1)
      ApplyHostSlot.create!(host_key: 'fresh.example', next_allowed_at: 1.hour.ago, holder_apply_id: 1)

      described_class.call

      expect(ApplyHostSlot.pluck(:host_key)).to eq([ 'fresh.example' ])
    end
  end
end
