# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Handler::Base do
  let(:handler_class) { Class.new(described_class) }
  let(:condition) { ->(ctx) { ctx.apply.external? } }

  before do
    handler_class.add_step ApplyEngineFakes::PrepareStep, if: condition
    handler_class.add_step ApplyEngineFakes::SubmitStep, label: 'fake'
  end

  describe '.add_step / .steps' do
    it 'keeps the declaration order with positions' do
      expect(handler_class.steps.map { |step| [ step.operation, step.position ] })
        .to eq([ [ ApplyEngineFakes::PrepareStep, 0 ], [ ApplyEngineFakes::SubmitStep, 1 ] ])
    end

    it 'stores the if: condition and the forwarded options' do
      prepare, submit = handler_class.steps

      expect(prepare.condition).to be(condition)
      expect(prepare.options).to eq({})
      expect(submit.condition).to be_nil
      expect(submit.options).to eq(label: 'fake')
    end

    it "keys each step by its operation's stage" do
      expect(handler_class.steps.map(&:key)).to eq(%w[fake_prepare fake_submit])
    end

    it 'keeps step lists per handler class' do
      expect(ApplyEngineFakes::Handler.steps.size).to eq(2)
      expect(Class.new(described_class).steps).to be_empty
    end
  end

  it 'raises for an operation without a declared stage' do
    step = described_class::Step.new(operation: Class.new(Apply::Operation::Base), condition: nil, options: {}, position: 0)

    expect { step.key }.to raise_error(NotImplementedError, /must declare stage/)
  end

  describe '#call' do
    it 'runs the pipeline through the Runner' do
      apply = build(:apply)
      handler = handler_class.new(apply:)
      allow(Apply::Operation::Engine::Run).to receive(:call)

      handler.call

      expect(Apply::Operation::Engine::Run).to have_received(:call).with(apply:, handler:)
    end
  end

  describe '.for' do
    it "resolves the handler from the source's scraper" do
      apply = create(:apply)
      apply.source_profile.source.update_columns(scraper: 'ApplyMate::Scraper::Djinni')

      expect(described_class.for(apply)).to be_a(Apply::Handler::Djinni)
    end

    it 'raises for a scraper without a handler' do
      apply = create(:apply)
      apply.source_profile.source.update_columns(scraper: 'ApplyMate::Scraper::Nope')

      expect { described_class.for(apply) }.to raise_error(RuntimeError, /No handler defined for scraper: Nope/)
    end
  end
end
