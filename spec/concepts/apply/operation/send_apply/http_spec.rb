# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::SendApply::Http do
  def http_response(status, body: '', location: nil)
    headers = location ? { 'location' => location } : {}
    ApplyMate::Client::AsyncHttp::Response.new(body, headers, status)
  end

  # The step as the only step of a real run (claim rule + Lifecycle), with the payload stubbed on its handler.
  def run_step
    run_engine_step(apply, described_class) { |handler| allow(handler).to receive(:build_payload).and_return(payload) }
  end

  context 'DOU internal apply (Coidea Agency)' do
    include_context 'coidea dou'

    let(:http_client) { instance_double(ApplyMate::Client::ImpersonateHttp) }
    let(:handler)     { instance_double(Apply::Handler::Base) }
    let(:payload) do
      { 'csrfmiddlewaretoken' => 'oT3J2ws9iVPG6NQGwgzRo2N0CGJ428nE87IOzxDNiX5OP907lcKlRKTxNt9843KR',
        'descr'               => 'I am an experienced UI/UX designer.' }
    end

    before do
      allow(ApplyMate::Client::ImpersonateHttp).to receive(:new).and_return(http_client)
      allow(handler).to receive(:build_payload).and_return(payload)

      apply.update!(
        action:        CoideaDou::VACANCY_URL,
        http_method:   'post',
        cookies:       'csrftoken=oT3J2ws9; sessionid=test-session-id',
        filled_inputs:,
        inputs:        filled_inputs
      )
    end

    describe '#call' do
      subject(:run_operation) { described_class.call(ctx: engine_context(apply), handler:) }

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

        it 'takes the submit claim before the POST' do
          claimed_at_post = nil
          allow(http_client).to receive(:post_multipart) do
            claimed_at_post = Apply.find(apply.id).submit_claimed_at
            http_response(200)
          end

          run_operation

          expect(claimed_at_post).to be_present
        end

        it 'completes the run, claim first, then submitted' do
          run_step

          expect(apply).to be_completed
          expect(apply.submit_claimed_at).to be_present
          expect(apply.submitted_at).to be >= apply.submit_claimed_at
          expect(apply.apply_steps.sole).to have_attributes(stage: 'submit', state: 'succeeded')
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
          described_class.call(ctx: engine_context(apply), handler: real_handler)
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload: hash_including('user_cv' => instance_of(Faraday::Multipart::FilePart)),
            headers: anything
          )
        end
      end

      context 'when building the payload fails' do
        before do
          allow(handler).to receive(:build_payload).and_raise(ActiveStorage::FileNotFoundError)
          allow(http_client).to receive(:post_multipart)
        end

        it 'never claims nor posts' do
          expect { run_operation }.to raise_error(ActiveStorage::FileNotFoundError)
          expect(apply.reload.submit_claimed_at).to be_nil
          expect(http_client).not_to have_received(:post_multipart)
        end
      end

      context 'when the server redirects to a different path (successful submission)' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(302, location: 'https://jobs.dou.ua/companies/coidea-agency/vacancies/356740/thankyou/'))
        end

        it 'treats the redirect as success and completes' do
          expect(run_step).to be_completed
        end
      end

      context 'when the server redirects back to the same vacancy page' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(302, location: CoideaDou::VACANCY_URL))
        end

        it 'halts with outcome_unknown' do
          expect { run_operation }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
            expect(halt).to have_attributes(code: :outcome_unknown, detail: CoideaDou::VACANCY_URL)
            expect(halt.releases_claim?).to be(false)
          }
        end

        it 'ends submit_unverified with the claim kept' do
          run_step

          expect(apply).to be_submit_unverified
          expect(apply.submit_claimed_at).to be_present
          expect(apply.submitted_at).to be_nil
          expect(apply.failure).to include('code' => 'outcome_unknown', 'stage' => 'submit', 'after_claim' => true)
        end
      end

      context 'when the server redirects to a login page (session expired)' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(302, location: 'https://jobs.dou.ua/login/?next=/apply'))
        end

        it 'halts definitively with session_expired' do
          expect { run_operation }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
            expect(halt.code).to eq(:session_expired)
            expect(halt.releases_claim?).to be(true)
          }
        end

        it 'releases the claim and asks the user to refresh the session' do
          run_step

          expect(apply).to be_needs_human
          expect(apply.submit_claimed_at).to be_nil
          expect(apply.failure).to include('code' => 'session_expired', 'after_claim' => true)
          expect(apply).to be_resumable
        end
      end

      context 'when the server returns a 5xx error' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(500, body: 'Internal Server Error'))
        end

        it 'ends submit_unverified with outcome_unknown and the claim kept' do
          run_step

          expect(apply).to be_submit_unverified
          expect(apply.submit_claimed_at).to be_present
          expect(apply.failure).to include('code' => 'outcome_unknown', 'detail' => 'HTTP 500')
        end
      end

      context 'when the POST gets no response' do
        before { allow(http_client).to receive(:post_multipart).and_return(nil) }

        it 'ends submit_unverified with outcome_unknown' do
          expect(run_step).to be_submit_unverified
          expect(apply.failure).to include('code' => 'outcome_unknown', 'detail' => 'no response')
        end
      end
    end
  end

  context 'Djinni internal apply (Art of Spin)' do
    include_context 'art of spin djinni'

    let(:http_client) { instance_double(ApplyMate::Client::AsyncHttp) }
    let(:handler)     { instance_double(Apply::Handler::Base) }
    let(:payload) do
      { 'apply'               => 'true',
        'message'             => 'I am an experienced 2D animator with 3+ years in Spine and slot games.',
        'csrfmiddlewaretoken' => 'xcW3TcF3cryx6WqIAuccBTJfa1cXKOOQKiqerZlIAs9HiddqVeobZzyBM3c2NJaz' }
    end

    before do
      allow(ApplyMate::Client::AsyncHttp).to receive(:new).and_return(http_client)
      allow(handler).to receive(:build_payload).and_return(payload)

      apply.update!(
        action:        ArtOfSpinDjinni::VACANCY_URL,
        http_method:   'post',
        cookies:       'csrftoken=xcW3TcF3; sessionid=test-session-id',
        filled_inputs:,
        inputs:        filled_inputs
      )
    end

    describe '#call' do
      subject(:run_operation) { described_class.call(ctx: engine_context(apply), handler:) }

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

        context 'when the page captured a different (anonymous) sessionid' do
          before do
            apply.update!(cookies: 'csrftoken=xcW3TcF3; sessionid=anonymous-captured-id')
          end

          it 'keeps the authenticated sessionid and does not duplicate or let the captured one override it' do
            run_operation
            cookie = nil
            expect(http_client).to have_received(:post_multipart) do |_action, headers:, **|
              cookie = headers['Cookie']
            end
            expect(cookie.scan(/sessionid=/).size).to eq(1)
            expect(cookie).to include('sessionid=test-session-id')
            expect(cookie).not_to include('anonymous-captured-id')
            expect(cookie).to include('csrftoken=xcW3TcF3')
          end
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

        it 'completes the run' do
          expect(run_step).to be_completed
          expect(apply.submitted_via).to eq('engine')
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
          described_class.call(ctx: engine_context(apply), handler: real_handler)
          expect(http_client).to have_received(:post_multipart).with(
            anything,
            payload: hash_including('cv_file' => instance_of(Faraday::Multipart::FilePart)),
            headers: anything
          )
        end
      end

      context 'when the server redirects back to the same vacancy page' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(302, location: ArtOfSpinDjinni::VACANCY_URL))
        end

        it 'ends submit_unverified with the claim kept' do
          expect(run_step).to be_submit_unverified
          expect(apply.submit_claimed_at).to be_present
          expect(apply.failure).to include('code' => 'outcome_unknown')
        end
      end

      context 'when the server returns a 5xx error' do
        before do
          allow(http_client).to receive(:post_multipart)
            .and_return(http_response(500, body: 'Internal Server Error'))
        end

        it 'ends submit_unverified with the claim kept' do
          expect(run_step).to be_submit_unverified
          expect(apply.submit_claimed_at).to be_present
          expect(apply.failure).to include('code' => 'outcome_unknown', 'detail' => 'HTTP 500')
        end
      end
    end
  end
end
