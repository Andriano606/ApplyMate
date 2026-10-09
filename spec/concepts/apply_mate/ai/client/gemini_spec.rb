# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Ai::Client::Gemini do
  subject(:client) { described_class.new(api_key: 'test-key', model: 'gemini-2.5-flash') }

  let(:endpoint) { %r{generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.5-flash:generateContent\?key=test-key} }
  let(:request) { ApplyMate::Ai::Request.for(kind: :verify, text: 'Did it work?') }
  let(:retrying) { ApplyMate::Ai::Request.for(kind: :verify, text: 'Did it work?', retries: 2) }
  let(:sent_bodies) { [] }

  before do
    allow(client).to receive(:sleep)
  end

  def stub_gemini(*responses)
    stub_request(:post, endpoint)
      .with { |req| sent_bodies << JSON.parse(req.body) }
      .to_return(*responses)
  end

  describe '.capabilities' do
    it 'declares json_schema and vision' do
      expect(described_class.capabilities).to eq(%i[json_schema vision])
      expect(described_class.supports?(:vision)).to be(true)
      expect(described_class.supports?(:browser_backed)).to be(false)
    end
  end

  describe '#complete' do
    it 'returns the candidate text and usage (thinking tokens counted as output)' do
      stub_gemini(gemini_json_response('{"success":true}', usage: { prompt: 120, candidates: 8, thoughts: 30 }))

      response = client.complete(request)

      expect(response).to eq(
        ApplyMate::Ai::Response.new(
          text:  '{"success":true}',
          usage: ApplyMate::Ai::Usage.new(input_tokens: 120, output_tokens: 38)
        )
      )
    end

    it 'returns Usage::UNKNOWN when usageMetadata is absent' do
      stub_gemini(gemini_json_response('ok'))

      expect(client.complete(request).usage).to eq(ApplyMate::Ai::Usage::UNKNOWN)
    end

    it 'sends answer cap + thinking budget, a bounded thinking_config and no structured-output fields without a schema' do
      stub_gemini(gemini_json_response('ok'))

      client.complete(request)

      body = sent_bodies.sole
      expect(body['contents']).to eq([ { 'role' => 'user', 'parts' => [ { 'text' => 'Did it work?' } ] } ])
      expect(body['generation_config']).to eq('max_output_tokens' => 1_024, 'thinking_config' => { 'thinking_budget' => 512 })
      expect(body).not_to have_key('system_instruction')
    end

    it 'sends system_instruction when the request has a system prompt' do
      stub_gemini(gemini_json_response('ok'))

      client.complete(ApplyMate::Ai::Request.for(kind: :navigate, text: 'x', system: 'You navigate.'))

      expect(sent_bodies.sole['system_instruction']).to eq('parts' => [ { 'text' => 'You navigate.' } ])
    end

    it 'appends images as inline_data parts on the user turn' do
      stub_gemini(gemini_json_response('ok'))
      image = { mime_type: 'image/png', data: 'aGk=' }

      client.complete(ApplyMate::Ai::Request.for(kind: :verify, text: 'x', images: [ image ]))

      expect(sent_bodies.sole.dig('contents', 0, 'parts')).to eq(
        [ { 'text' => 'x' }, { 'inline_data' => { 'mime_type' => 'image/png', 'data' => 'aGk=' } } ]
      )
    end

    it 'uses the request timeout for the HTTP client' do
      allow(Gemini).to receive(:new).and_call_original
      stub_gemini(gemini_json_response('ok'))

      client.complete(request)

      expect(Gemini).to have_received(:new).with(
        hash_including(options: hash_including(connection: { request: { timeout: 30 } }))
      )
    end

    context 'with a json_schema' do
      let(:schema) do
        {
          type:                 'object',
          additionalProperties: false,
          required:             %w[success reason],
          properties:           {
            success: { type: 'boolean', description: 'did it work' },
            reason:  { type: %w[string null] },
            tags:    { type: 'array', items: { type: 'string', enum: %w[a b] } }
          }
        }
      end

      it 'sends response_mime_type and a Gemini-dialect response_schema' do
        stub_gemini(gemini_json_response('{}'))

        client.complete(ApplyMate::Ai::Request.for(kind: :answers, text: 'x', json_schema: schema))

        expect(sent_bodies.sole['generation_config']).to eq(
          'max_output_tokens'  => 6_144,
          'thinking_config'    => { 'thinking_budget' => 2_048 },
          'response_mime_type' => 'application/json',
          'response_schema'    => {
            'type'       => 'OBJECT',
            'required'   => %w[success reason],
            'properties' => {
              'success' => { 'type' => 'BOOLEAN', 'description' => 'did it work' },
              'reason'  => { 'type' => 'STRING', 'nullable' => true },
              'tags'    => { 'type' => 'ARRAY', 'items' => { 'type' => 'STRING', 'enum' => %w[a b] } }
            }
          }
        )
      end

      it 'rejects a union of several non-null types' do
        bad = { type: 'object', properties: { x: { type: %w[string integer] } } }

        expect { client.complete(ApplyMate::Ai::Request.for(kind: :answers, text: 'x', json_schema: bad)) }
          .to raise_error(ArgumentError, /one non-null type/)
      end
    end

    it 'retries a 503 and returns the following 200' do
      stub_gemini({ status: 503, body: '{"error":{"code":503}}' }, gemini_json_response('recovered'))

      expect(client.complete(retrying).text).to eq('recovered')
      expect(client).to have_received(:sleep).with(2).once
    end

    it 'gives up after two retries' do
      stub_gemini({ status: 503, body: '' })

      expect { client.complete(retrying) }.to raise_error(/503/)
      expect(a_request(:post, endpoint)).to have_been_made.times(3)
    end

    it 'does not retry a 503 when the request says retries: 0 (the default of a verify request)' do
      stub_gemini({ status: 503, body: '' })

      expect { client.complete(request) }.to raise_error(/503/)
      expect(a_request(:post, endpoint)).to have_been_made.once
    end

    it 'raises Unavailable for a quota 429, with the API key scrubbed from the message and the log' do
      stub_gemini({ status: 429, body: '{"error":{"code":429,"status":"RESOURCE_EXHAUSTED"}}' })
      allow(Rails.logger).to receive(:error)

      expect { client.complete(request) }.to raise_error(ApplyMate::Ai::Client::Base::Unavailable) { |error|
        expect(error.message).to include('429').and include('key=[REDACTED]')
        expect(error.message).not_to include('test-key')
      }
      expect(Rails.logger).to have_received(:error).with(satisfy { |line| !line.include?('test-key') })
    end

    it 'does not retry a 400: a ProviderError naming the Faraday class, scrubbed, with no cause chain' do
      stub_gemini({ status: 400, body: '{"error":{"code":400}}' })

      expect { client.complete(request) }.to raise_error(ApplyMate::Ai::Client::Base::ProviderError) { |error|
        expect(error).not_to be_a(ApplyMate::Ai::Client::Base::Unavailable)
        expect(error.message).to start_with('Faraday::BadRequestError:').and(satisfy { |message| !message.include?('test-key') })
        expect(error.cause).to be_nil
      }
      expect(a_request(:post, endpoint)).to have_been_made.once
    end

    context 'with a real-shaped API key' do
      subject(:client) { described_class.new(api_key: google_key, model: 'gemini-2.5-flash') }

      let(:google_key) { "AIza#{SecureRandom.alphanumeric(35)}" }
      let(:endpoint) { %r{generativelanguage\.googleapis\.com/v1beta/models/gemini-2\.5-flash:generateContent} }

      it 'keeps the key out of the message, the cause chain and the log of a 5xx the gem wraps' do
        stub_gemini({ status: 500, body: '{"error":{"code":500,"status":"INTERNAL"}}' })
        allow(Rails.logger).to receive(:error)

        expect { client.complete(request) }.to raise_error(ApplyMate::Ai::Client::Base::Unavailable) { |error|
          expect(error.full_message(highlight: false)).not_to include(google_key)
          expect(error.cause).to be_nil
        }
        expect(Rails.logger).to have_received(:error).with(satisfy { |line| !line.include?(google_key) })
      end

      it 'raises QuotaExhausted without retrying when the daily quota is used up' do
        body = { error: { code: 429, status: 'RESOURCE_EXHAUSTED', message: 'You exceeded your current quota.',
                          details: [ { violations: [ { quotaId: 'GenerateRequestsPerDayPerProjectPerModel-FreeTier' } ] },
                                     { retryDelay: '67247s' } ] } }.to_json
        stub_gemini({ status: 429, body: })

        expect { client.complete(retrying) }.to raise_error(ApplyMate::Ai::Client::Base::QuotaExhausted) { |error|
          expect(error.message).to include('PerDay').and(satisfy { |message| !message.include?(google_key) })
        }
        expect(a_request(:post, endpoint)).to have_been_made.once
      end

      it 'treats a long retryDelay as an exhausted quota and a per-minute limit as transient' do
        stub_gemini({ status: 429, body: { error: { code: 429, details: [ { retryDelay: '7200s' } ] } }.to_json })
        expect { client.complete(request) }.to raise_error(ApplyMate::Ai::Client::Base::QuotaExhausted)

        stub_gemini({ status: 429, body: { error: { code: 429, details: [ { quotaId: 'GenerateRequestsPerMinutePerProjectPerModel' },
                                                                            { retryDelay: '27s' } ] } }.to_json })
        expect { client.complete(request) }.to raise_error(ApplyMate::Ai::Client::Base::Unavailable)
      end

      it 'validates the key with the x-goog-api-key header, never in the URL' do
        stub_request(:get, 'https://generativelanguage.googleapis.com/v1beta/models')
          .with(headers: { 'x-goog-api-key' => google_key }).to_return(status: 200, body: '{"models":[]}')

        expect { described_class.validate_api_key!(api_key: google_key) }.not_to raise_error
      end
    end

    it 'raises naming finishReason when the candidate has no text' do
      stub_gemini(
        status:  200,
        body:    { candidates: [ { finishReason: 'MAX_TOKENS', content: { parts: [] } } ],
                   usageMetadata: { promptTokenCount: 10, thoughtsTokenCount: 512 } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

      expect { client.complete(request) }
        .to raise_error(ApplyMate::Ai::Client::Base::EmptyResponse, /finishReason: "MAX_TOKENS".*thoughtsTokenCount: 512/)
    end

    it 'raises naming blockReason when the prompt was blocked' do
      stub_gemini(
        status:  200,
        body:    { promptFeedback: { blockReason: 'SAFETY' } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

      expect { client.complete(request) }.to raise_error(ApplyMate::Ai::Client::Base::EmptyResponse, /blockReason: "SAFETY"/)
    end

    describe 'thinking_config gating by model' do
      %w[gemini-2.5-flash gemini-2.5-pro gemini-2.5-flash-lite gemini-2.5-flash-preview-09-2025
         gemini-3-pro-preview gemini-3.1-flash].each do |model|
        it "bounds thinking for #{model}" do
          stub_request(:post, /generateContent/).with { |req| sent_bodies << JSON.parse(req.body) }
                                                .to_return(gemini_json_response('ok'))

          described_class.new(api_key: 'test-key', model:).complete(request)

          expect(sent_bodies.sole['generation_config']).to include('thinking_config' => { 'thinking_budget' => 512 })
        end
      end

      %w[gemini-2.0-flash gemini-1.5-pro gemini-2.5-flash-image-preview].each do |model|
        it "omits thinking_config for #{model} but keeps the raised cap" do
          stub_request(:post, /generateContent/).with { |req| sent_bodies << JSON.parse(req.body) }
                                                .to_return(gemini_json_response('ok'))

          described_class.new(api_key: 'test-key', model:).complete(request)

          expect(sent_bodies.sole['generation_config']).to eq('max_output_tokens' => 1_024)
        end
      end
    end
  end
end
