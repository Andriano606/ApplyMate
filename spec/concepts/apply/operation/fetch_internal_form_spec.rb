# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::FetchInternalForm do
  context 'Djinni internal apply (Art of Spin)' do
    include_context 'art of spin djinni'

    let(:http_client) { instance_double(ApplyMate::Client::AsyncHttp) }

    before do
      allow(ApplyMate::Client::AsyncHttp).to receive(:new).and_return(http_client)
      allow(http_client).to receive(:get).and_return(
        ApplyMate::Client::AsyncHttp::Response.new(
          djinni_apply_html,
          { 'set-cookie' => 'sessionid=test-session-id; Path=/; HttpOnly' },
          200,
          ArtOfSpinDjinni::VACANCY_URL
        )
      )
    end

    describe '#call' do
      subject(:run_operation) { described_class.call(apply:) }

      it 'fetches the vacancy page with the session cookie' do
        run_operation
        expect(http_client).to have_received(:get).with(
          ArtOfSpinDjinni::VACANCY_URL,
          headers:          hash_including('Cookie' => 'sessionid=test-session-id'),
          follow_redirects: true
        )
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

      context 'when the page returns several Set-Cookie headers (Django + Cloudflare)' do
        before do
          allow(http_client).to receive(:get).and_return(
            ApplyMate::Client::AsyncHttp::Response.new(
              djinni_apply_html,
              { 'set-cookie' => [ 'csrftoken=tok-abc; Path=/', 'sessionid=anon-xyz; Path=/; HttpOnly' ] },
              200,
              ArtOfSpinDjinni::VACANCY_URL
            )
          )
        end

        it 'captures every cookie, including the csrftoken needed for the CSRF-protected POST' do
          run_operation
          expect(apply.reload.cookies).to eq('csrftoken=tok-abc; sessionid=anon-xyz')
        end
      end
    end
  end

  context 'DOU internal apply (Coidea Agency)' do
    include_context 'coidea dou'

    let(:http_client) { instance_double(ApplyMate::Client::AsyncHttp) }

    before do
      allow(ApplyMate::Client::AsyncHttp).to receive(:new).and_return(http_client)
      allow(http_client).to receive(:get).and_return(
        ApplyMate::Client::AsyncHttp::Response.new(
          dou_apply_html,
          { 'set-cookie' => 'sessionid=test-session-id; Path=/; HttpOnly' },
          200,
          CoideaDou::VACANCY_URL
        )
      )
    end

    describe '#call' do
      subject(:run_operation) { described_class.call(apply:) }

      it 'fetches the vacancy page with the session cookie' do
        run_operation
        expect(http_client).to have_received(:get).with(
          CoideaDou::VACANCY_URL,
          headers:          hash_including('Cookie' => 'sessionid=test-session-id'),
          follow_redirects: true
        )
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
