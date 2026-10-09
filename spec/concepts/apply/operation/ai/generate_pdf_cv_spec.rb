# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Ai::GeneratePdfCv do
  let(:apply)   { create(:apply, raw_cv: '%PDF-1.4 fake') }
  let(:handler) { Apply::Handler::Base.new(apply:) }
  let(:options) { { prompt_class: Apply::Ai::Prompt::GenerateCv, schema_class: Apply::Ai::ResponseSchema::GenerateCv } }

  subject(:run_operation) { described_class.call(ctx: engine_context(apply), handler:, **options) }

  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    allow(VacancyCv::TurboHandler::Index).to receive(:broadcast)
  end

  it 'is the generate_cv stage Apply.with_cv_or_generating_cv lists as a placeholder' do
    expect(described_class.stage.to_s).to eq('generate_cv')
    apply.update_columns(state: Apply.states[:running], stage: described_class.stage.to_s)

    expect(Apply.with_cv_or_generating_cv).to include(apply)
  end

  it 'attaches the CV, shows the placeholder through the whole list, then refreshes only its row' do
    allow(VacancyCv::TurboHandler::Index).to receive(:broadcast_row)

    expect(run_operation).to be_success

    expect(apply.reload.cv).to be_attached
    expect(VacancyCv::TurboHandler::Index).to have_received(:broadcast).with(apply.vacancy, apply.user)
    expect(VacancyCv::TurboHandler::Index).to have_received(:broadcast_row).with(apply, leaving: false)
  end

  context 'when the cleanup broadcast of the CV list fails' do
    before { allow(VacancyCv::TurboHandler::Index).to receive(:broadcast_row).and_raise('cable down') }

    it 'still finishes the step with the CV attached' do
      expect { run_operation }.not_to raise_error
      expect(apply.reload.cv).to be_attached
    end

    it 'keeps the original exception when the step itself failed' do
      allow(apply.cv).to receive(:attach).and_raise('storage down')

      expect { run_operation }.to raise_error(RuntimeError, 'storage down')
    end
  end

  context 'when the step fails inside the Runner' do
    before do
      allow(VacancyCv::TurboHandler::Index).to receive(:broadcast_row)
      allow(Rails.error).to receive(:report)
    end

    it 'removes the placeholder row and records the failed generate_cv step' do
      run_engine_step(apply, described_class, **options) do |runner_handler|
        allow(runner_handler).to receive(:cv_filename).and_raise('storage down')
      end

      expect(VacancyCv::TurboHandler::Index).to have_received(:broadcast_row).with(apply, leaving: true)
      expect(apply).to be_failed
      expect(apply.failure).to include('code' => 'unexpected_error', 'stage' => 'generate_cv')
      expect(apply.apply_steps.sole).to have_attributes(stage: 'generate_cv', state: 'failed')
    end
  end
end
