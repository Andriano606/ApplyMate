# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::ResponseSchema::Browser::CheckSubmitResult do
  describe '.extract' do
    it 'returns a valid verdict' do
      result = described_class.extract("```json\n{\"success\": false, \"reason\": \"Error banner shown\"}\n```")

      expect(result).to eq('success' => false, 'reason' => 'Error banner shown')
      expect(result[:success]).to be(false)
    end

    # Strict: an unusable verdict raises; the Runner records invalid_ai_output and the claim rule keeps it
    # submit_unverified, never success.
    [ '', 'garbage', '{"success": "maybe", "reason": "?"}', '{"success": false}' ].each do |raw|
      it "raises InvalidResponse for an unusable answer (#{raw.inspect})" do
        expect { described_class.extract(raw) }.to raise_error(ApplyMate::Ai::ResponseSchema::Json::InvalidResponse)
      end
    end
  end

  it 'is sent natively (fixed properties)' do
    expect(described_class.native_schema?).to be(true)
  end
end
