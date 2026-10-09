# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::ResponseSchema::Navigate do
  let(:click) { { type: 'click', ref: 'f1:e2', key: nil, index: nil, max_ms: nil } }
  let(:continue) { { status: 'continue', reason: 'Application tab', actions: [ click ], form: nil, give_up_code: nil } }

  def extract(payload)
    described_class.extract(payload.is_a?(String) ? payload : payload.to_json)
  end

  it 'is a natively sent :navigate schema' do
    expect(described_class.kind).to eq(:navigate)
    expect(described_class.native_schema?).to be(true)
  end

  it 'reads a continue, a form_reached and a give_up decision' do
    form = { frame: 'f1', scope_ref: 'f1:e10', field_refs: %w[f1:e11 f1:e12], submit_ref: 'f1:e40', advance_ref: nil }
    reached = { status: 'form_reached', reason: '17 new fields', actions: [], form:, give_up_code: nil }
    give_up = { status: 'give_up', reason: 'login', actions: [], form: nil, give_up_code: 'login_required' }

    expect(extract(continue)).to include('status' => 'continue', 'actions' => [ include('type' => 'click', 'ref' => 'f1:e2') ])
    expect(extract("```json\n#{reached.to_json}\n```")['form']).to include('scope_ref' => 'f1:e10', 'submit_ref' => 'f1:e40')
    expect(extract(give_up)).to include('give_up_code' => 'login_required')
  end

  it 'has no fill action and takes only the closed vocabulary, keys and give-up codes' do
    expect(described_class::ACTION_TYPES).to eq(%w[click press scroll navigate switch_tab wait])
    expect(described_class.json_schema.to_json).not_to include('fill')

    [ continue.merge(actions: [ click.merge(type: 'fill') ]),
      continue.merge(actions: [ click.merge(type: 'press', key: 'a') ]),
      continue.merge(status: 'done'),
      continue.merge(give_up_code: 'tired'),
      continue.merge(actions: [ click ] * 4),
      continue.merge(actions: [ click.merge(value: 'x') ]),
      continue.merge(extra: 1),
      continue.except(:form) ].each do |payload|
      expect { extract(payload) }.to raise_error(ApplyMate::Ai::ResponseSchema::Json::InvalidResponse), payload.to_json
    end
  end

  it 'describes the format and the action rules for clients without a native schema' do
    expect(described_class.format_instructions).to include('"status"', '"give_up_code"', 'At most 3 actions', 'captcha_challenge')
  end

  describe 'as a Gemini responseSchema' do
    let(:integration) { create(:ai_integration) }
    let(:endpoint) { %r{generativelanguage\.googleapis\.com.*generateContent} }

    it 'keeps the enums (null moved to nullable), maxItems and the nested items' do
      stub_request(:post, endpoint).to_return(gemini_json_response(continue.to_json))
      prompt = instance_double(ApplyMate::Ai::Prompt::Base, call: 'page')

      ApplyMate::Ai::AiHandler.complete(prompt_instance: prompt, response_schema_class: described_class,
                                        ai_integration: integration)

      sent = nil
      expect(a_request(:post, endpoint).with { |request| sent = JSON.parse(request.body) }).to have_been_made
      schema = sent.dig('generation_config', 'response_schema') || sent.dig('generationConfig', 'responseSchema')
      properties = schema['properties']
      expect(properties['status']).to eq('type' => 'STRING', 'enum' => described_class::STATUSES)
      expect(properties['give_up_code']).to eq('type' => 'STRING', 'nullable' => true, 'enum' => described_class::GIVE_UP_CODES)
      expect(properties['actions']).to include('type' => 'ARRAY', 'maxItems' => 3)
      action = properties.dig('actions', 'items', 'properties')
      expect(action['type']).to eq('type' => 'STRING', 'enum' => described_class::ACTION_TYPES)
      expect(action['key']).to eq('type' => 'STRING', 'nullable' => true, 'enum' => %w[ArrowDown Enter Escape Tab])
      expect(properties['form']).to include('type' => 'OBJECT', 'nullable' => true)
      expect(schema.to_json).not_to include('additionalProperties')
    end
  end
end
