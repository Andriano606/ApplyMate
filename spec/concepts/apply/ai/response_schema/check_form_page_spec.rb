# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::ResponseSchema::CheckFormPage do
  let(:invalid) { ApplyMate::Ai::ResponseSchema::Json::InvalidResponse }

  describe '.extract' do
    it 'returns the four keys from a fenced answer' do
      raw = "```json\n{\"has_form\":false,\"trigger_selector\":\"button.apply\",\"form_url\":null,\"form_selector\":null}\n```"

      expect(described_class.extract(raw)).to eq(
        'has_form' => false, 'trigger_selector' => 'button.apply', 'form_url' => nil, 'form_selector' => nil
      )
    end

    it 'raises on a blank answer instead of defaulting to has_form: false' do
      expect { described_class.extract('') }.to raise_error(invalid)
    end

    it 'raises when has_form is not a boolean' do
      expect { described_class.extract('{"has_form": "yes"}') }.to raise_error(invalid)
    end

    it 'raises when a required key is missing' do
      expect { described_class.extract('{"has_form": true, "form_selector": "form"}') }
        .to raise_error(invalid, /trigger_selector/)
    end
  end

  it 'is sent natively (fixed properties)' do
    expect(described_class.native_schema?).to be(true)
  end
end
