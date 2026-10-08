# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::Browser::Operation::WaitForListbox do
  let(:clock) { ApplyMate::Client::Browser::Clock }
  let(:now) { [ 0.0 ] }
  let(:driver) { instance_double(ApplyMate::Client::Browser::Driver::Playwright, remaining_ms: 60_000) }
  let(:frame_path) { [ { 'selector' => 'iframe#embed' } ] }
  let(:since) { { frame_path:, option_count: 0, containers: { 'frame' => {}, 'top' => {} } } }
  let(:option_target) { ApplyMate::Client::Browser::Target.css('#opt') }
  let(:reads) { [] }

  before do
    allow(clock).to receive(:now_ms) { now.first }
    allow(clock).to receive(:sleep_ms) { |milliseconds| now[0] += milliseconds }
    allow(ApplyMate::Client::Browser::Operation::ReadListbox).to receive(:call) do
      ApplyMate::Operation::Result.new.tap { |result| result[:model] = reads.size > 1 ? reads.shift : reads.first }
    end
  end

  def scope(*options)
    { 'containers' => {}, 'options' => options.map { |label, disabled| { 'label' => label, 'disabled' => disabled,
                                                                         'target' => option_target } } }
  end

  it 'polls the field frame and the top document until new options appear' do
    reads.push({ 'frame' => scope, 'top' => scope },
               { 'frame' => scope([ 'Word of mouth', false ], [ 'Gone', true ]), 'top' => scope([ 'Portal', false ]) })

    options = described_class.call(driver:, since:, timeout_ms: 5_000).model

    expect(options).to eq([ described_class::Option.new(label: 'Word of mouth', target: option_target),
                            described_class::Option.new(label: 'Portal', target: option_target) ])
    expect(ApplyMate::Client::Browser::Operation::ReadListbox).to have_received(:call)
      .with(driver:, frame_path:, since: since[:containers]).twice
    expect(now.first).to eq(100.0)
  end

  it 'returns [] at the timeout when nothing opens' do
    reads.push({ 'top' => scope })

    expect(described_class.call(driver:, since:, timeout_ms: 1_000).model).to eq([])
    expect(now.first).to eq(1_000.0)
  end
end
