# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Ai::AiHandler do
  subject(:call_handler) do
    described_class.call(
      prompt_instance:       prompt,
      response_schema_class:,
      ai_integration:
    )
  end

  let(:response_schema_class) { Apply::Ai::ResponseSchema::VerifySubmit }
  let(:prompt) { instance_double(ApplyMate::Ai::Prompt::Base, call: 'Was the application submitted?') }
  let(:ai_integration) { create(:ai_integration) }
  let(:endpoint) { /generativelanguage\.googleapis\.com.*generateContent/ }
  let(:verdict) { { 'submitted' => false, 'confidence' => 0.4, 'quote' => 'Error banner' } }

  context 'with a Gemini integration' do
    before do
      stub_request(:post, endpoint).to_return(
        gemini_json_response("```json\n#{verdict.to_json}\n```",
                             usage: { prompt: 50, candidates: 7 })
      )
      allow(Rails.logger).to receive(:info).and_call_original
    end

    it "returns the schema's extracted value" do
      expect(call_handler).to eq(verdict)
    end

    it 'sends prompt + format instructions sized by the schema kind' do
      call_handler

      expect(
        a_request(:post, endpoint).with do |req|
          body = JSON.parse(req.body)
          text = body.dig('contents', 0, 'parts', 0, 'text')
          text.include?('Was the application submitted?') &&
            text.include?('Return one JSON object: {"submitted"') &&
            body['generation_config'].slice('max_output_tokens', 'thinking_config') ==
              { 'max_output_tokens' => 1_024, 'thinking_config' => { 'thinking_budget' => 512 } }
        end
      ).to have_been_made.once
    end

    it 'logs client, kind and token usage under the AiHandler tag' do
      call_handler

      expect(Rails.logger).to have_received(:info).with(
        /\[ApplyMate::Ai::AiHandler\] ApplyMate::Ai::Client::Gemini kind=verify input_tokens=50 output_tokens=7/
      )
    end

    describe '.complete' do
      subject(:outcome) { described_class.complete(prompt_instance: prompt, response_schema_class:, ai_integration:, request_options:) }

      let(:request_options) { {} }

      it 'returns the parsed data together with the provider usage' do
        expect(outcome).to have_attributes(data: verdict,
                                           usage: ApplyMate::Ai::Usage.new(input_tokens: 50, output_tokens: 7))
      end

      it 'attaches the usage of an unusable answer to the InvalidResponse it raises' do
        stub_request(:post, endpoint).to_return(gemini_json_response('not json', usage: { prompt: 33, candidates: 4 }))

        expect { outcome }.to raise_error(ApplyMate::Ai::ResponseSchema::Json::InvalidResponse) { |error|
          expect(error.usage).to eq(ApplyMate::Ai::Usage.new(input_tokens: 33, output_tokens: 4))
        }
      end

      context 'with request_options' do
        let(:request_options) { { system: 'Be brief', timeout: 12, retries: 0 } }

        before { stub_request(:post, endpoint).to_return(status: 503, body: 'overloaded') }

        it 'sends the system instruction and does not retry a 503 when retries is 0' do
          expect { outcome }.to raise_error(StandardError, /503/)

          expect(a_request(:post, endpoint).with { |req| JSON.parse(req.body).dig('system_instruction', 'parts', 0, 'text') == 'Be brief' })
            .to have_been_made.once
        end
      end

      it 'retries a 503 up to the kind default when retries is not overridden' do
        stub_request(:post, endpoint).to_return({ status: 503, body: 'x' }, { status: 503, body: 'x' }, { status: 503, body: 'x' })
        allow_any_instance_of(ApplyMate::Ai::Client::Gemini).to receive(:sleep) # rubocop:disable RSpec/AnyInstance
        handler = described_class.new
        answers_schema = Apply::Ai::ResponseSchema::AnswerFields

        expect { handler.complete(prompt_instance: prompt, response_schema_class: answers_schema, ai_integration:) }.to raise_error(StandardError)
        expect(a_request(:post, endpoint)).to have_been_made.times(3)
      end
    end

    {
      Apply::Ai::ResponseSchema::VerifySubmit             => [ %w[submitted confidence quote],
                                                              '{"submitted":true,"confidence":0.9,"quote":"Thanks"}' ],
      Apply::Ai::ResponseSchema::Navigate                 => [
        %w[status reason actions form give_up_code],
        '{"status":"give_up","reason":"closed","actions":[],"form":null,"give_up_code":"closed_posting"}'
      ],
      VacancyQuestion::Ai::ResponseSchema::AnswerQuestion => [ %w[answer], '{"answer":"Yes"}' ]
    }.each do |schema_class, (required, answer)|
      context "with the native schema #{schema_class.name.demodulize}" do
        let(:response_schema_class) { schema_class }

        before { stub_request(:post, endpoint).to_return(gemini_json_response(answer)) }

        it 'sends it as the Gemini response_schema and still appends format_instructions' do
          call_handler

          expect(
            a_request(:post, endpoint).with do |req|
              body = JSON.parse(req.body)
              config = body['generation_config']
              config['response_mime_type'] == 'application/json' &&
                config.dig('response_schema', 'type') == 'OBJECT' &&
                config.dig('response_schema', 'required') == required &&
                body.dig('contents', 0, 'parts', 0, 'text').include?(schema_class.format_instructions.lines.first.strip)
            end
          ).to have_been_made.once
        end
      end
    end

    context 'with the text-mode FillForm schema' do
      let(:response_schema_class) { Apply::Ai::ResponseSchema::FillForm }

      before do
        stub_request(:post, endpoint).to_return(gemini_json_response("```json\n{\"name\":\"Jane\"}\n```"))
      end

      it 'omits response_schema and response_mime_type' do
        expect(call_handler).to eq('name' => 'Jane')
        expect(
          a_request(:post, endpoint).with do |req|
            config = JSON.parse(req.body)['generation_config']
            config == { 'max_output_tokens' => 6_144, 'thinking_config' => { 'thinking_budget' => 2_048 } }
          end
        ).to have_been_made.once
      end
    end
  end
end
