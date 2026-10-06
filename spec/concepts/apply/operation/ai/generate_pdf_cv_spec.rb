# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Ai::GeneratePdfCv do
  let(:apply)   { create(:apply, raw_cv: '%PDF-1.4 fake') }
  let(:handler) { Apply::Handler::Base.new(apply:) }

  subject(:run_operation) do
    described_class.call(
      apply:, handler:,
      prompt_class: Apply::Ai::Prompt::GenerateCv, schema_class: Apply::Ai::ResponseSchema::GenerateCv
    )
  end

  before do
    allow(Apply::TurboHandler::StatusUpdate).to receive(:broadcast)
    allow(VacancyCv::TurboHandler::Index).to receive(:broadcast)
  end

  it 'shows the placeholder through the whole list, then refreshes only its row' do
    allow(VacancyCv::TurboHandler::Index).to receive(:broadcast_row)

    run_operation

    expect(VacancyCv::TurboHandler::Index).to have_received(:broadcast).with(apply.vacancy, apply.user)
    expect(VacancyCv::TurboHandler::Index).to have_received(:broadcast_row).with(apply)
  end

  context 'when the cleanup broadcast of the CV list fails' do
    before { allow(VacancyCv::TurboHandler::Index).to receive(:broadcast_row).and_raise('cable down') }

    it 'still finishes the step with the CV attached and no error' do
      expect { run_operation }.not_to raise_error
      expect(apply.reload).to be_generating_cv
      expect(apply.error).to be_nil
      expect(apply.cv).to be_attached
    end

    it 'keeps the original exception and the failed status when the step itself failed' do
      allow(apply.cv).to receive(:attach).and_raise('storage down')

      expect { run_operation }.to raise_error(RuntimeError, 'storage down')
      expect(apply.reload).to be_failed_generating_cv
      expect(apply.error).to eq('storage down')
    end
  end
end
