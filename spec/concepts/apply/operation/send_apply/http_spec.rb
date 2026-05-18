# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::SendApply::Http do
  def http_response(status, body: '', location: nil)
    headers = location ? { 'location' => location } : {}
    ApplyMate::Client::AsyncHttp::Response.new(body, headers, status)
  end

  context 'DOU internal apply (Coidea Agency)' do
    include_context 'coidea dou'

    let(:http_client) { instance_double(ApplyMate::Client::AsyncHttp) }
    let(:handler)     { instance_double(Apply::Handler::Base) }

    before do
      allow(ApplyMate::Client::AsyncHttp).to receive(:new).and_return(http_client)
      allow(handler).to receive(:build_payload).and_return(
        'csrfmiddlewaretoken' => 'oT3J2ws9iVPG6NQGwgzRo2N0CGJ428nE87IOzxDNiX5OP907lcKlRKTxNt9843KR',
        'descr'               => 'I am an experienced UI/UX designer.'
      )

      apply.update!(
        action:        CoideaDou::VACANCY_URL,
        http_method:   'post',
        cookies:       'csrftoken=oT3J2ws9; sessionid=test-session-id',
        filled_inputs:,
        inputs:        filled_inputs
      )
    end

    describe '#call' do
      subject(:run_operation) { described_class.call(apply:, handler:) }

      context 'when the server responds 200 OK' do
        before { allow(http_client).to receive(:post_multipart).and_return(http_response(200)) }

        it 'posts to the form action URL' do
          run_operation
          expect(http_client).to have_received(:post_multipart)
            .with(CoideaDou::VACANCY_URL, payload: anything, headers: anything)
        end

        it 'sends the session cookie and page cookies in the Cookie header' do
          run_operation
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload:  anything,
            headers:  hash_including('Cookie' => include('sessionid=test-session-id', 'csrftoken=oT3J2ws9'))
          )
        end

        it 'sends the vacancy URL as the Referer' do
          run_operation
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload:  anything,
            headers:  hash_including('Referer' => CoideaDou::VACANCY_URL)
          )
        end

        it 'passes the built payload to the request' do
          run_operation
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload:  hash_including('descr' => 'I am an experienced UI/UX designer.'),
            headers:  anything
          )
        end

        it 'marks the apply as completed' do
          run_operation
          expect(apply.reload.status).to eq('completed')
        end

        it 'completes without an error' do
          run_operation
          expect(apply.reload.error).to be_nil
        end
      end

      context 'when a CV is attached' do
        let(:real_handler) { Apply::Handler::Dou.new(apply:) }

        before do
          apply.cv.attach(
            io:           StringIO.new('%PDF-1.4 fake-cv'),
            filename:     'Jane_Doe_CV.pdf',
            content_type: 'application/pdf'
          )
          allow(http_client).to receive(:post_multipart).and_return(http_response(200))
        end

        it 'includes the CV as a multipart file part under the file input name' do
          described_class.call(apply:, handler: real_handler)
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload: hash_including('user_cv' => instance_of(Faraday::Multipart::FilePart)),
            headers: anything
          )
        end
      end

      context 'when the server redirects to a different path (successful submission)' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(302, location: 'https://jobs.dou.ua/companies/coidea-agency/vacancies/356740/thankyou/'))
        end

        it 'treats the redirect as success and completes' do
          run_operation
          expect(apply.reload.status).to eq('completed')
          expect(apply.reload.error).to be_nil
        end
      end

      # For error cases: Apply::Operation::Base updates status/error then re-raises,
      # so use raise_error to catch the propagated error while still asserting DB state.

      context 'when the server redirects back to the same vacancy page (rejected)' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(302, location: CoideaDou::VACANCY_URL))
        end

        it 'marks the apply as failed with a rejection message' do
          expect { run_operation }.to raise_error(RuntimeError, /Submission rejected/)
          expect(apply.reload.status).to eq('failed_sending_cv')
          expect(apply.reload.error).to match(/Submission rejected/)
        end
      end

      context 'when the server redirects to a login page (session expired)' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(302, location: 'https://jobs.dou.ua/login/?next=/apply'))
        end

        it 'marks the apply as failed with a rejection message' do
          expect { run_operation }.to raise_error(RuntimeError, /Submission rejected/)
          expect(apply.reload.status).to eq('failed_sending_cv')
          expect(apply.reload.error).to match(/Submission rejected/)
        end
      end

      context 'when the server returns a 5xx error' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(500, body: 'Internal Server Error'))
        end

        it 'marks the apply as failed with the HTTP status' do
          expect { run_operation }.to raise_error(RuntimeError, /HTTP 500/)
          expect(apply.reload.status).to eq('failed_sending_cv')
          expect(apply.reload.error).to match(/HTTP 500/)
        end
      end
    end
  end

  context 'Djinni internal apply (Art of Spin)' do
    include_context 'art of spin djinni'

    let(:http_client) { instance_double(ApplyMate::Client::AsyncHttp) }
    let(:handler)     { instance_double(Apply::Handler::Base) }

    before do
      allow(ApplyMate::Client::AsyncHttp).to receive(:new).and_return(http_client)
      allow(handler).to receive(:build_payload).and_return(
        'apply'               => 'true',
        'message'             => 'I am an experienced 2D animator with 3+ years in Spine and slot games.',
        'csrfmiddlewaretoken' => 'xcW3TcF3cryx6WqIAuccBTJfa1cXKOOQKiqerZlIAs9HiddqVeobZzyBM3c2NJaz'
      )

      apply.update!(
        action:        ArtOfSpinDjinni::VACANCY_URL,
        http_method:   'post',
        cookies:       'csrftoken=xcW3TcF3; sessionid=test-session-id',
        filled_inputs:,
        inputs:        filled_inputs
      )
    end

    describe '#call' do
      subject(:run_operation) { described_class.call(apply:, handler:) }

      context 'when the server responds 200 OK' do
        before { allow(http_client).to receive(:post_multipart).and_return(http_response(200)) }

        it 'posts to the Djinni vacancy URL (form has no action attribute)' do
          run_operation
          expect(http_client).to have_received(:post_multipart)
            .with(ArtOfSpinDjinni::VACANCY_URL, payload: anything, headers: anything)
        end

        it 'sends the session cookie and page cookies in the Cookie header' do
          run_operation
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload:  anything,
            headers:  hash_including('Cookie' => include('sessionid=test-session-id', 'csrftoken=xcW3TcF3'))
          )
        end

        it 'sends the vacancy URL as the Referer' do
          run_operation
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload:  anything,
            headers:  hash_including('Referer' => ArtOfSpinDjinni::VACANCY_URL)
          )
        end

        it 'passes the message field in the payload' do
          run_operation
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload:  hash_including('message' => 'I am an experienced 2D animator with 3+ years in Spine and slot games.'),
            headers:  anything
          )
        end

        it 'marks the apply as completed' do
          run_operation
          expect(apply.reload.status).to eq('completed')
        end

        it 'completes without an error' do
          run_operation
          expect(apply.reload.error).to be_nil
        end
      end

      context 'when a CV is attached' do
        let(:real_handler) { Apply::Handler::Djinni.new(apply:) }

        before do
          apply.cv.attach(
            io:           StringIO.new('%PDF-1.4 fake-cv'),
            filename:     'Jane_Doe_CV.pdf',
            content_type: 'application/pdf'
          )
          allow(http_client).to receive(:post_multipart).and_return(http_response(200))
        end

        it 'includes the CV as a multipart file part under cv_file' do
          described_class.call(apply:, handler: real_handler)
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload: hash_including('cv_file' => instance_of(Faraday::Multipart::FilePart)),
            headers: anything
          )
        end
      end

      context 'when the server redirects back to the same vacancy page (rejected)' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(302, location: ArtOfSpinDjinni::VACANCY_URL))
        end

        it 'marks the apply as failed with a rejection message' do
          expect { run_operation }.to raise_error(RuntimeError, /Submission rejected/)
          expect(apply.reload.status).to eq('failed_sending_cv')
          expect(apply.reload.error).to match(/Submission rejected/)
        end
      end

      context 'when the server returns a 5xx error' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(500, body: 'Internal Server Error'))
        end

        it 'marks the apply as failed with the HTTP status' do
          expect { run_operation }.to raise_error(RuntimeError, /HTTP 500/)
          expect(apply.reload.status).to eq('failed_sending_cv')
          expect(apply.reload.error).to match(/HTTP 500/)
        end
      end
    end
  end
end
