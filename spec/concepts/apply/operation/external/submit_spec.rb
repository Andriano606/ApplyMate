# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::External::Submit do
  include_context 'honeytech dou'

  let(:handler) { Apply::Handler::Dou.new(apply:) }

  before do
    stub_request(:post, /generativelanguage\.googleapis\.com.*generateContent/)
      .to_return(gemini_check_submit_result)
  end

  describe '#call' do
    subject(:run_operation) { described_class.call(apply:, handler:) }

    context 'with adapter-sourced fields' do
      before do
        apply.update!(
          resolved_url: 'https://boards.greenhouse.io/acme/jobs/4045807008',
          ats: 'greenhouse', fields_source: 'adapter',
          filled_inputs: [ { 'name' => 'email', 'type' => 'text', 'value' => 'dev@example.com' } ]
        )
      end

      it 'submits via the adapter API and completes' do
        expect_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:post_multipart)
          .with('https://boards.greenhouse.io/acme/jobs/4045807008', anything)
          .and_return(ApplyMate::Client::AsyncHttp::Response.new('', {}, 200, nil))

        run_operation
        expect(apply.reload.status).to eq('completed')
        expect(browser).not_to have_received(:click_by_handle)
      end

      it 'fails the apply when the adapter submission is rejected' do
        allow_any_instance_of(ApplyMate::Client::AsyncHttp).to receive(:post_multipart)
          .and_return(ApplyMate::Client::AsyncHttp::Response.new('nope', {}, 403, nil))

        expect { run_operation }.to raise_error(Apply::ExternalAts::Base::AdapterError)
        expect(apply.reload.status).to eq('failed_sending_cv')
      end
    end

    context 'with browser-sourced fields' do
      before do
        handler.browser = browser
        apply.update!(
          external_url: HoneytechDou::DOU_REDIRECT, fields_source: 'browser',
          submit_handle: 'submit', filled_inputs:
        )
      end

      it 'delegates to the live browser session' do
        run_operation
        expect(browser).to have_received(:fill_by_handle).with(0, 'Jane Doe', 'input')
        expect(browser).to have_received(:click_by_handle).with('submit')
        expect(apply.reload.status).to eq('completed')
      end
    end
  end
end
