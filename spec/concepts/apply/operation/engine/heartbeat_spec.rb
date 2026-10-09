# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Heartbeat do
  it 'starts a timer task every INTERVAL seconds that the caller shuts down' do
    ctx = engine_context(create(:apply))
    task = described_class.call(ctx:).model

    expect(task).to be_a(Concurrent::TimerTask)
    expect(task).to be_running
    expect(task.execution_interval).to eq(described_class::INTERVAL)
  ensure
    task&.shutdown
  end

  it 'runs Tick on the timer thread and reports a failing tick to Rails.error' do
    stub_const("#{described_class}::INTERVAL", 0.05)
    ctx = engine_context(create(:apply))
    allow(Apply::Operation::Engine::Heartbeat::Tick).to receive(:call).and_raise(ActiveRecord::ConnectionTimeoutError)
    reports = Queue.new
    allow(Rails.error).to receive(:report) { |error, **options| reports << [ error, options ] }
    task = described_class.call(ctx:).model

    error, options = reports.pop(timeout: 5)

    expect(error).to be_a(ActiveRecord::ConnectionTimeoutError)
  ensure
    task&.shutdown
  end
end
