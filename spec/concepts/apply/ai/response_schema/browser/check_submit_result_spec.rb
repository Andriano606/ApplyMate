# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::ResponseSchema::Browser::CheckSubmitResult do
  describe '.extract' do
    it 'returns a valid verdict' do
      result = described_class.extract("```json\n{\"success\": false, \"reason\": \"Error banner shown\"}\n```")

      expect(result).to eq('success' => false, 'reason' => 'Error banner shown')
      expect(result[:success]).to be(false)
    end

    # Lenient until phase 1 introduces claim + submit_unverified (design §15 rows 0/1).
    [ '', 'garbage', '{"success": "maybe", "reason": "?"}', '{"success": false}' ].each do |raw|
      it "falls back to success for an unusable answer (#{raw.inspect})" do
        expect(described_class.extract(raw)).to eq('success' => true, 'reason' => 'Could not parse AI response')
      end
    end

    it 'returns indifferent access on the fallback too' do
      expect(described_class.extract('garbage')[:success]).to be(true)
    end
  end

  it 'is sent natively (fixed properties)' do
    expect(described_class.native_schema?).to be(true)
  end
end
