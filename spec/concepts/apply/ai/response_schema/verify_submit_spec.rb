# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::ResponseSchema::VerifySubmit do
  def extract(text)
    described_class.extract(text)
  end

  it 'is a :verify schema' do
    expect(described_class.kind).to eq(:verify)
  end

  it 'reads submitted, confidence and quote' do
    json = { submitted: true, confidence: 0.9, quote: 'Thank you for applying' }.to_json

    expect(extract("```json\n#{json}\n```")).to include('submitted' => true, 'confidence' => 0.9, 'quote' => 'Thank you for applying')
  end

  it 'rejects a missing key, an out-of-range confidence, a non-boolean verdict and stray keys' do
    [ '{"submitted":true,"confidence":0.9}', '{"submitted":true,"confidence":1.5,"quote":""}',
      '{"submitted":"yes","confidence":0.9,"quote":""}', '{"submitted":true,"confidence":0.9,"quote":"","extra":1}' ].each do |json|
      expect { extract(json) }.to raise_error(ApplyMate::Ai::ResponseSchema::Json::InvalidResponse)
    end
  end

  it 'describes the format' do
    expect(described_class.format_instructions).to include('"submitted"', '"confidence"', '"quote"')
  end
end
