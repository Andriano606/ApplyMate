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

    it 'browses with a profile belonging to the job board, not a throwaway one' do
      expect(ApplyMate::Client::Browser).to receive(:new).with(profile: 'dou').and_return(browser)
      run_operation
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

    context 'when the employer page only embeds the form in an iframe (Preply/Ashby)' do
      let(:embed_page)  { 'https://preply.com/en/careers/apply?ashby_jid=a9419d80' }
      let(:form_page)   { 'https://jobs.ashbyhq.com/preply/a9419d80/application' }

      before do
        allow(browser).to receive(:current_url).and_return(embed_page, form_page)
        allow(browser).to receive(:field_count).and_return(0)
        allow(browser).to receive(:wait_for_fields).and_return(false)
        allow(browser).to receive(:iframe_sources).and_return(
          [ 'https://jobs.ashbyhq.com/preply/a9419d80?embed=js',
            'https://web.cmp.usercentrics.eu/cdcs/index.html' ]
        )
      end

      it 'follows the embed to the standalone form page' do
        run_operation
        expect(browser).to have_received(:navigate_to).with(form_page)
        expect(apply.reload.resolved_url).to eq(form_page)
      end

      it 'records the ATS detected on the embed page' do
        run_operation
        expect(apply.reload.ats).to eq('ashby')
      end
    end

    context 'when the page has its own fields' do
      before do
        allow(browser).to receive(:field_count).and_return(6)
        allow(browser).to receive(:iframe_sources).and_return([ 'https://jobs.ashbyhq.com/x/y?embed=js' ])
      end

      it 'does not follow any iframe' do
        run_operation
        expect(browser).to have_received(:navigate_to).once
        expect(apply.reload.resolved_url).to eq(HoneytechDou::PEOPLEFORCE_URL)
      end
    end

    context 'when the page has no fields and no usable iframe' do
      before do
        allow(browser).to receive(:field_count).and_return(0)
        allow(browser).to receive(:wait_for_fields).and_return(false)
        allow(browser).to receive(:iframe_sources).and_return([ 'https://consent.cookiebot.com/x.html' ])
      end

      it 'keeps the resolved URL and lets the browser path continue' do
        run_operation
        expect(browser).to have_received(:navigate_to).once
        expect(apply.reload.resolved_url).to eq(HoneytechDou::PEOPLEFORCE_URL)
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
