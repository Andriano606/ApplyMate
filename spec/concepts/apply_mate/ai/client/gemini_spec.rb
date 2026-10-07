# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Ai::Client::Gemini do
  subject(:client) { described_class.new(api_key: 'test-key', model: 'gemini-2.5-flash') }

  let(:endpoint) { %r{generativelanguage\.googleapis\.com/v1/models/gemini-2\.5-flash:generateContent\?key=test-key} }
  let(:request) { ApplyMate::Ai::Request.for(kind: :verify, text: 'Did it work?') }
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

      expect(client.complete(request).text).to eq('recovered')
      expect(client).to have_received(:sleep).with(2).once
    end

    it 'gives up after two retries' do
      stub_gemini({ status: 503, body: '' })

      expect { client.complete(request) }.to raise_error(/503/)
      expect(a_request(:post, endpoint)).to have_been_made.times(3)
    end

    it 'does not retry a 400' do
      stub_gemini({ status: 400, body: '{"error":{"code":400}}' })

      expect { client.complete(request) }.to raise_error(Faraday::BadRequestError)
      expect(a_request(:post, endpoint)).to have_been_made.once
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
