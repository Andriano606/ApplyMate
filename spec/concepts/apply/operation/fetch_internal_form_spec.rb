# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::FetchInternalForm do
  context 'Djinni internal apply (Art of Spin)' do
    include_context 'art of spin djinni'

    before do
      stub_request(:get, ArtOfSpinDjinni::VACANCY_URL)
        .to_return(
          status:  200,
          body:    djinni_apply_html,
          headers: { 'Content-Type' => 'text/html; charset=utf-8',
                     'Set-Cookie'   => 'sessionid=test-session-id; Path=/; HttpOnly' }
        )
    end

    describe '#call' do
      subject(:run_operation) { described_class.call(apply:) }

      it 'fetches the vacancy page with the session cookie' do
        run_operation
        expect(WebMock).to have_requested(:get, ArtOfSpinDjinni::VACANCY_URL)
          .with(headers: { 'Cookie' => 'sessionid=test-session-id' })
      end

      it 'extracts the Djinni apply form fields' do
        run_operation
        field_names = apply.reload.inputs.map { |i| i['name'] }
        expect(field_names).to include('message', 'cv_file', 'csrfmiddlewaretoken')
      end

      it 'resolves the form action to the vacancy URL (form has no action attribute)' do
        run_operation
        expect(apply.reload.action).to eq(ArtOfSpinDjinni::VACANCY_URL)
      end

      it 'stores POST as the http method' do
        run_operation
        expect(apply.reload.http_method).to eq('post')
      end

      it 'stores the submit selector for the apply button' do
        run_operation
        expect(apply.reload.submit_selector).to eq('#job_apply')
      end

      it 'stores cookies from the response' do
        run_operation
        expect(apply.reload.cookies).to include('sessionid=test-session-id')
      end

      it 'detects the cover-letter textarea' do
        run_operation
        message = apply.reload.inputs.find { |i| i['name'] == 'message' }
        expect(message).to include('tag' => 'textarea', 'type' => 'textarea')
      end

      it 'detects the CV file input' do
        run_operation
        cv = apply.reload.inputs.find { |i| i['name'] == 'cv_file' }
        expect(cv).to include('type' => 'file')
      end

      it 'completes without an error' do
        run_operation
        expect(apply.reload.error).to be_nil
      end
    end
  end

  context 'DOU internal apply (Coidea Agency)' do
    include_context 'coidea dou'

    before do
      stub_request(:get, CoideaDou::VACANCY_URL)
        .to_return(
          status:  200,
          body:    dou_apply_html,
          headers: { 'Content-Type'  => 'text/html; charset=utf-8',
                     'Set-Cookie'    => 'sessionid=test-session-id; Path=/; HttpOnly' }
        )
    end

    describe '#call' do
      subject(:run_operation) { described_class.call(apply:) }

      it 'fetches the vacancy page with the session cookie' do
        run_operation
        expect(WebMock).to have_requested(:get, CoideaDou::VACANCY_URL)
          .with(headers: { 'Cookie' => 'sessionid=test-session-id' })
      end

      it 'extracts the DOU apply form fields' do
        run_operation
        field_names = apply.reload.inputs.map { |i| i['name'] }
        expect(field_names).to include('descr', 'user_cv', 'csrfmiddlewaretoken')
      end

      it 'resolves the form action to the vacancy URL (form has no action attribute)' do
        run_operation
        expect(apply.reload.action).to eq(CoideaDou::VACANCY_URL)
      end

      it 'stores POST as the http method' do
        run_operation
        expect(apply.reload.http_method).to eq('post')
      end

      it 'stores cookies from the response' do
        run_operation
        expect(apply.reload.cookies).to include('sessionid=test-session-id')
      end

      it 'detects the cover-letter textarea' do
        run_operation
        descr = apply.reload.inputs.find { |i| i['name'] == 'descr' }
        expect(descr).to include('tag' => 'textarea', 'type' => 'textarea')
      end

      it 'detects the CV file input' do
        run_operation
        cv = apply.reload.inputs.find { |i| i['name'] == 'user_cv' }
        expect(cv).to include('type' => 'file')
      end

      it 'completes without an error' do
        run_operation
        expect(apply.reload.error).to be_nil
      end
    end
  end
end
