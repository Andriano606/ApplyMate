# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::External::FetchFields do
  include_context 'honeytech dou'

  let(:vacancy_external_url) { HoneytechDou::DOU_REDIRECT }
  let(:handler) { Apply::Handler::Dou.new(apply:) }

  describe '#call' do
    subject(:run_operation) { described_class.call(apply:, handler:) }

    context 'with a detected ATS and a working adapter' do
      let(:job_json) { File.read(Rails.root.join('spec/fixtures/files/ats/greenhouse_job.json')) }

      before do
        apply.update!(resolved_url: 'https://boards.greenhouse.io/acme/jobs/4045807008', ats: 'greenhouse')
        allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
          .and_return(ApplyMate::Client::AsyncHttp::Response.new(job_json, {}, 200, nil))
      end

      it 'stores API-sourced fields with roles and marks the adapter source' do
        run_operation
        reloaded = apply.reload
        expect(reloaded.fields_source).to eq('adapter')
        expect(reloaded.inputs.map { |i| i['role'] }).to include('first_name', 'email', 'cv_file')
      end

      it 'does not touch the browser' do
        run_operation
        expect(browser).not_to have_received(:page_digest)
        expect(browser).not_to have_received(:snapshot_fields)
      end
    end

    context 'when the adapter fails (API changed)' do
      before do
        apply.update!(resolved_url: 'https://boards.greenhouse.io/acme/jobs/4045807008', ats: 'greenhouse')
        allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:get)
          .and_return(ApplyMate::Client::AsyncHttp::Response.new('gone', {}, 410, nil))

        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_check_form_page)
      end

      it 'falls back to the browser path' do
        run_operation
        reloaded = apply.reload
        expect(reloaded.fields_source).to eq('browser')
        expect(reloaded.inputs.map { |i| i['name'] }).to include('career_application_form[full_name]')
      end
    end

    context 'without a detected ATS' do
      before do
        stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
          .to_return(gemini_check_form_page)
      end

      it 'uses the browser path and keeps resolve data intact' do
        apply.update!(resolved_url: HoneytechDou::PEOPLEFORCE_URL, ats: nil)
        run_operation
        reloaded = apply.reload
        expect(reloaded.fields_source).to eq('browser')
        expect(reloaded.resolved_url).to eq(HoneytechDou::PEOPLEFORCE_URL) # not wiped by PrepareSession
        expect(reloaded.inputs).to be_present
      end
    end
  end
end
