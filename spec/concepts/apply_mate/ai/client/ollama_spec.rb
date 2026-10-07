# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Ai::Client::Ollama do
  subject(:client) { described_class.new(host: 'http://ollama.test:11434/', model: 'llama3.1') }

  let(:endpoint) { 'http://ollama.test:11434/api/chat' }
  let(:sent_bodies) { [] }

  def stub_ollama(*responses)
    stub_request(:post, endpoint)
      .with { |req| sent_bodies << JSON.parse(req.body) }
      .to_return(*responses)
  end

  describe '.capabilities' do
    it 'declares json_schema only' do
      expect(described_class.capabilities).to eq(%i[json_schema])
      expect(described_class.supports?(:vision)).to be(false)
    end
  end

  describe '#complete' do
    it 'returns the message content and usage from prompt_eval_count / eval_count' do
      stub_ollama(ollama_chat_response('{"answer":"hi"}', prompt_eval_count: 812, eval_count: 41))

      response = client.complete(ApplyMate::Ai::Request.for(kind: :answers, text: 'Answer'))

      expect(response).to eq(
        ApplyMate::Ai::Response.new(
          text:  '{"answer":"hi"}',
          usage: ApplyMate::Ai::Usage.new(input_tokens: 812, output_tokens: 41)
        )
      )
    end

    it "sends a non-streaming chat with num_ctx and num_predict = the kind's answer cap + thinking budget" do
      stub_ollama(ollama_chat_response('ok', prompt_eval_count: 1, eval_count: 1))

      client.complete(ApplyMate::Ai::Request.for(kind: :navigate, text: 'Where is the form?'))

      expect(sent_bodies.sole).to eq(
        'model'    => 'llama3.1',
        'stream'   => false,
        'messages' => [ { 'role' => 'user', 'content' => 'Where is the form?' } ],
        'options'  => { 'num_ctx' => 16_384, 'num_predict' => 2_048 }
      )
    end

    it 'prepends the system message and sends the schema hash as format' do
      stub_ollama(ollama_chat_response('{}', prompt_eval_count: 1, eval_count: 1))
      schema = { type: 'object', properties: { answer: { type: 'string' } }, required: [ 'answer' ] }

      client.complete(ApplyMate::Ai::Request.for(kind: :verify, text: 'x', system: 'Be strict', json_schema: schema))

      body = sent_bodies.sole
      expect(body['messages']).to eq(
        [ { 'role' => 'system', 'content' => 'Be strict' }, { 'role' => 'user', 'content' => 'x' } ]
      )
      expect(body['format']).to eq(schema.deep_stringify_keys)
      expect(body['options']).to eq('num_ctx' => 16_384, 'num_predict' => 1_024)
    end

    it 'uses the request timeout for the HTTP client' do
      allow(Ollama).to receive(:new).and_call_original
      stub_ollama(ollama_chat_response('ok', prompt_eval_count: 1, eval_count: 1))

      client.complete(ApplyMate::Ai::Request.for(kind: :cv, text: 'x'))

      expect(Ollama).to have_received(:new).with(
        credentials: { address: 'http://ollama.test:11434' },
        options:     { server_sent_events: false, connection: { request: { timeout: 180 } } }
      )
    end

    it 'raises CapabilityMissing on images without sending anything' do
      request = ApplyMate::Ai::Request.for(kind: :verify, text: 'x', images: [ { mime_type: 'image/png', data: 'aGk=' } ])

      expect { client.complete(request) }.to raise_error(ApplyMate::Ai::Client::Base::CapabilityMissing, /vision/)
      expect(a_request(:post, endpoint)).not_to have_been_made
    end

    it 'raises when the reply has no message content' do
      stub_ollama(status: 200, body: { done: true, done_reason: 'length' }.to_json)

      expect { client.complete(ApplyMate::Ai::Request.for(kind: :verify, text: 'x')) }
        .to raise_error(ApplyMate::Ai::Client::Base::EmptyResponse, /done_reason: "length"/)
    end

    it 'raises on a non-JSON body' do
      stub_ollama(status: 200, body: 'upstream proxy error')

      expect { client.complete(ApplyMate::Ai::Request.for(kind: :verify, text: 'x')) }
        .to raise_error(RuntimeError, /non-JSON body/)
    end
  end
end
