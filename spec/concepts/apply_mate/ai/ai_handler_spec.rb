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

  let(:response_schema_class) { Apply::Ai::ResponseSchema::Browser::CheckSubmitResult }
  let(:prompt) { instance_double(ApplyMate::Ai::Prompt::Base, call: 'Was the application submitted?') }
  let(:ai_integration) { create(:ai_integration) }
  let(:endpoint) { /generativelanguage\.googleapis\.com.*generateContent/ }

  context 'with a Gemini integration' do
    before do
      stub_request(:post, endpoint).to_return(
        gemini_json_response("```json\n{\"success\":false,\"reason\":\"Error banner\"}\n```",
                             usage: { prompt: 50, candidates: 7 })
      )
      allow(Rails.logger).to receive(:info).and_call_original
    end

    it "returns the schema's extracted value" do
      expect(call_handler).to eq('success' => false, 'reason' => 'Error banner')
    end

    it 'sends prompt + format instructions sized by the schema kind' do
      call_handler

      expect(
        a_request(:post, endpoint).with do |req|
          body = JSON.parse(req.body)
          text = body.dig('contents', 0, 'parts', 0, 'text')
          text.include?('Was the application submitted?') &&
            text.include?('Return a JSON object with exactly two keys') &&
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

    {
      Apply::Ai::ResponseSchema::CheckFormPage              => [
        %w[has_form trigger_selector form_url form_selector],
        '{"has_form":true,"trigger_selector":null,"form_url":null,"form_selector":"form"}'
      ],
      Apply::Ai::ResponseSchema::Browser::CheckSubmitResult => [ %w[success reason], '{"success":true,"reason":"ok"}' ],
      VacancyQuestion::Ai::ResponseSchema::AnswerQuestion   => [ %w[answer], '{"answer":"Yes"}' ]
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
