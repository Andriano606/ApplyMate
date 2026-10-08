# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Stage::Verify do
  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:session) { FakeSession.new(html: '', final_url: 'https://jobs.ashbyhq.com/preply/x/application') }
  let(:png) { "\x89PNG\r\n\x1A\nfake".b }
  let(:signals) { { 'success_text' => true, 'url_match' => false, 'submit_request' => true, 'ai' => false } }

  def verdict(status, count: 2, field_errors: [])
    Apply::Operation::Engine::VerifySubmit::Verdict.new(
      status:, evidence: { 'signals' => signals, 'count' => count, 'min_signals' => 2, 'form_present' => false,
                           'field_errors' => field_errors, 'mutations_2xx' => 1, 'requests' => 1 }
    )
  end

  def stub_verdict(value)
    result = ApplyMate::Operation::Result.new
    result[:model] = value
    allow(Apply::Operation::Engine::VerifySubmit).to receive(:call).with(ctx:).and_return(result)
  end

  def verify!
    described_class.call(ctx:)
  end

  before do
    ctx.open_scope!(:submit, session, 5.minutes.from_now)
    allow(session).to receive(:screenshot).and_return(png)
  end

  it 'has a localized stage name' do
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :uk)).to be_present
    expect(I18n.t("apply.stage.#{described_class.stage}", locale: :en)).to be_present
  end

  context 'when the submit is verified' do
    before { stub_verdict(verdict(:submitted)) }

    it 'attaches a masked full-page screenshot and traces the verdict' do
      expect(verify![:step_result]).to eq('status' => 'submitted', 'signals' => signals)
      expect(session).to have_received(:screenshot).with(full_page: true, mask_fillable: true)
      expect(apply.screenshot).to be_attached
      expect(apply.screenshot.download).to eq(png)
      expect(ctx.scratch.trace.last).to include('event' => 'verdict', 'status' => 'submitted', 'count' => 2)
    end

    it 'still succeeds when the screenshot fails (the submit happened)' do
      allow(session).to receive(:screenshot).and_raise(RuntimeError, 'page closed')

      expect(verify![:step_result]).to include('status' => 'submitted')
      expect(apply.screenshot).not_to be_attached
      expect(ctx.scratch.trace.pluck('event')).to include('screenshot_failed')
    end
  end

  context 'when the page proves the submit was blocked client-side' do
    before { stub_verdict(verdict(:rejected, count: 0, field_errors: %w[ashby:email])) }

    it 'halts validation_rejected as definitive (releases the claim)' do
      expect { verify! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :validation_rejected, releases_claim?: true, detail: 'field errors: ashby:email')
      }
      expect(apply.screenshot).not_to be_attached
    end
  end

  context 'when the outcome is not proven either way' do
    before { stub_verdict(verdict(:unknown, count: 1)) }

    it 'halts outcome_unknown (not definitive: the claim stays)' do
      expect { verify! }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :outcome_unknown, releases_claim?: false, detail: 'signals 1/2')
      }
    end
  end
end
