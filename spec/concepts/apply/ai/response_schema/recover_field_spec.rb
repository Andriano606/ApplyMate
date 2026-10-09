# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::ResponseSchema::RecoverField do
  let(:click) { { type: 'click', ref: 'f0:e2', key: nil, index: nil, max_ms: nil } }
  let(:press) { { type: 'press', ref: 'f0:e1', key: 'ArrowDown', index: nil, max_ms: nil } }
  let(:turn) { { actions: [ click, press ], reason: 'open the menu', give_up: false } }

  def extract(payload)
    described_class.extract(payload.to_json)
  end

  it 'is a natively sent :navigate schema' do
    expect(described_class.kind).to eq(:navigate)
    expect(described_class.native_schema?).to be(true)
  end

  it 'reads click / press actions and a give-up' do
    expect(extract(turn)).to include('give_up' => false, 'actions' => [ include('type' => 'click'), include('key' => 'ArrowDown') ])
    expect(extract(actions: [], reason: 'format not allowed', give_up: true)).to include('give_up' => true, 'actions' => [])
  end

  it 'shares the Navigate action item but allows only click and press, at most 3' do
    expect(described_class.json_schema.dig(:properties, :actions, :items))
      .to eq(Apply::Ai::ResponseSchema::Navigate.action_schema(types: %w[click press]))

    [ turn.merge(actions: [ click.merge(type: 'navigate') ]),
      turn.merge(actions: [ click.merge(type: 'fill') ]),
      turn.merge(actions: [ click ] * 4),
      turn.merge(actions: [ press.merge(key: 'a') ]),
      turn.merge(extra: 1),
      turn.except(:give_up) ].each do |payload|
      expect { extract(payload) }.to raise_error(ApplyMate::Ai::ResponseSchema::Json::InvalidResponse), payload.to_json
    end
  end

  it 'describes the format for clients without a native schema' do
    expect(described_class.format_instructions).to include('"give_up"', '"click"|"press"', 'At most 3 actions', 'FIELD ELEMENTS')
  end
end
