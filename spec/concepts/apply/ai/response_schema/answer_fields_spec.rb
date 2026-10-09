# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::ResponseSchema::AnswerFields do
  def extract(text)
    described_class.extract(text)
  end

  it 'is an answers schema with dynamic keys, so it is never sent natively' do
    expect(described_class.kind).to eq(:answers)
    expect(described_class.native_schema?).to be(false)
  end

  it 'accepts every value type with a confidence in 0..1' do
    json = {
      a: { value: 'text', confidence: 0.5 }, b: { value: 3, confidence: 1 }, c: { value: true, confidence: 0 },
      d: { value: %w[x y], confidence: 0.7 }, e: { value: nil, confidence: 0.1 }
    }.to_json

    expect(extract("```json\n#{json}\n```").keys).to eq(%w[a b c d e])
  end

  it 'rejects a missing confidence, an out-of-range confidence and stray keys' do
    [ '{"a":{"value":"x"}}', '{"a":{"value":"x","confidence":1.5}}', '{"a":{"value":"x","confidence":0.5,"extra":1}}',
      '{"a":"x"}', '{"a":{"value":{"n":1},"confidence":0.5}}' ].each do |json|
      expect { extract(json) }.to raise_error(ApplyMate::Ai::ResponseSchema::Json::InvalidResponse)
    end
  end

  it 'describes the format' do
    expect(described_class.format_instructions).to include('confidence')
  end
end
