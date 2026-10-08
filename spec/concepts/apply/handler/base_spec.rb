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
    step = described_class::Step.new(operation: Class.new(Apply::Operation::Base), condition: nil, options: {}, scope: nil,
                                       position: 0)

    expect { step.key }.to raise_error(NotImplementedError, /must declare stage/)
  end

  describe '.session_scope' do
    let(:scoped) do
      Class.new(described_class) do
        add_step ApplyEngineFakes::PrepareStep
        session_scope(:survey, if: ->(ctx) { ctx.attempt == 1 }) do
          add_step ApplyEngineFakes::DigestOne
          add_step ApplyEngineFakes::DigestTwo, replay: true
        end
        add_step ApplyEngineFakes::SubmitStep
      end
    end

    it 'tags the steps declared inside with the scope and keeps the rest scope-less' do
      expect(scoped.steps.map(&:scope)).to eq([ nil, :survey, :survey, nil ])
    end

    it 'records the scope condition' do
      expect(scoped.scope_conditions.keys).to eq([ :survey ])
      expect(scoped.scope_conditions[:survey].call(Struct.new(:attempt).new(1))).to be(true)
    end

    it 'builds keys as stage[:replay][:scope]' do
      expect(scoped.steps.map(&:key)).to eq(%w[fake_prepare fake_digest_one:survey fake_digest_two:replay:survey fake_submit])
    end

    it 'refuses nested scopes' do
      expect { Class.new(described_class) { session_scope(:a) { session_scope(:b) { nil } } } }
        .to raise_error(ArgumentError, /do not nest/)
    end

    it 'resets the current scope after a block that raised' do
      klass = Class.new(described_class)
      expect { klass.session_scope(:a) { raise 'boom' } }.to raise_error('boom')

      klass.add_step ApplyEngineFakes::PrepareStep
      expect(klass.steps.sole.scope).to be_nil
    end
  end

  describe '.engine!' do
    # Stand-ins for stages of the later units (replaced by the real classes once they exist).
    let(:engine_stages) do
      { 'ReachForm' => :navigate, 'DiscoverFields' => :discover, 'AnswerFields' => :answer, 'ReviewGate' => :review,
        'FillFields' => :fill, 'Submit' => :submit, 'Verify' => :verify }.transform_values do |stage_name|
        Class.new(Apply::Operation::Stage::Base) { stage stage_name }
      end
    end
    let(:guard) { ->(ctx) { ctx.apply.external? } }
    let(:detect_guard) { ->(_ctx) { true } }
    let(:engine) { Class.new(described_class).tap { |klass| klass.engine!(detect_if: detect_guard, if: guard) } }

    before do
      engine_stages.each do |name, klass|
        next if Apply::Operation::Stage.const_defined?(name, false)

        stub_const("Apply::Operation::Stage::#{name}", klass)
      end
    end

    it 'declares the engine pipeline with the survey and submit scopes' do
      expect(engine.steps.map(&:key)).to eq(
        %w[detect schema navigate:survey discover:survey answer generate_cv review throttle
           navigate:replay:submit discover:submit fill:submit submit:submit verify:submit]
      )
      expect(engine.scope_conditions.keys).to eq(%i[survey submit])
    end

    it 'puts detect_if on DetectPlatform, platform_reachable? on the pre-form stages and if: on the rest' do
      steps = engine.steps.index_by(&:key)
      ctx = instance_double(Apply::Operation::Engine::Context, platform_reachable?: true, survey_needed?: true)

      expect(steps['detect'].condition).to be(detect_guard)
      expect(steps['schema'].condition.call(ctx)).to be(true)
      allow(ctx).to receive(:platform_reachable?).and_return(false)
      expect(steps['schema'].condition.call(ctx)).to be(false)
      expect(steps['navigate:survey'].condition).to be_nil
      expect(steps['discover:survey'].condition).to be(guard)
      expect(steps['review'].condition).to be(guard)
      expect(engine.scope_conditions[:submit]).to be(guard)
    end

    it 'runs the survey scope for a reachable platform while the form is not reachable directly with a known schema' do
      survey = engine.scope_conditions[:survey]
      ctx = instance_double(Apply::Operation::Engine::Context, survey_needed?: true, platform_reachable?: true)

      expect(survey.call(ctx)).to be(true)
      allow(ctx).to receive(:survey_needed?).and_return(false)
      expect(survey.call(ctx)).to be(false)
      allow(ctx).to receive_messages(survey_needed?: true, platform_reachable?: false)
      expect(survey.call(ctx)).to be(false)
    end

    it 'keeps the CV prompt and schema options of the legacy pipeline' do
      cv = engine.steps.find { |step| step.operation == Apply::Operation::Ai::GeneratePdfCv }

      expect(cv.options).to eq(prompt_class: Apply::Ai::Prompt::GenerateCv, schema_class: Apply::Ai::ResponseSchema::GenerateCv)
    end

    it 'leaves the scope conditions bare without if:' do
      bare = Class.new(described_class) { engine! }

      expect(bare.steps.first.condition).to be_nil
      expect(bare.scope_conditions[:submit]).to be_nil
      ctx = instance_double(Apply::Operation::Engine::Context, survey_needed?: true, platform_reachable?: true)
      expect(bare.scope_conditions[:survey].call(ctx)).to be(true)
    end
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
