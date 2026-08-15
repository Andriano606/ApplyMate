# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::External::Resolve do
  include_context 'honeytech dou'

  let(:vacancy_external_url) { HoneytechDou::DOU_REDIRECT }
  let(:handler) { Apply::Handler::Dou.new(apply:) }

  describe '#call' do
    subject(:run_operation) { described_class.call(apply:, handler:) }

    it 'opens the shared session and follows redirects to the final URL' do
      run_operation
      expect(browser).to have_received(:navigate_to).with(HoneytechDou::DOU_REDIRECT)
      expect(handler.browser).to be(browser)
      expect(apply.reload.resolved_url).to eq(HoneytechDou::PEOPLEFORCE_URL)
    end

    it 'records no ATS for a self-hosted page' do
      run_operation
      expect(apply.reload.ats).to be_nil
    end

    context 'when the redirect lands on a known ATS' do
      before do
        allow(browser).to receive(:current_url)
          .and_return('https://boards.greenhouse.io/acme/jobs/123')
      end

      it 'records the detected ATS and the resolved URL' do
        run_operation
        reloaded = apply.reload
        expect(reloaded.ats).to eq('greenhouse')
        expect(reloaded.resolved_url).to eq('https://boards.greenhouse.io/acme/jobs/123')
      end
    end

    context 'when the vacancy has no external URL' do
      let(:vacancy_external_url) { nil }

      it 'fails with a fetching-form error' do
        expect { run_operation }.to raise_error(/No external apply URL/)
        expect(apply.reload.status).to eq('failed_fetching_form')
      end
    end
  end
end
