# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Ai::ResponseSchema::FillForm do
  let(:invalid) { ApplyMate::Ai::ResponseSchema::Json::InvalidResponse }

  describe '.extract' do
    it 'returns the input-name map from a fenced answer' do
      email = unique_email('jane')
      raw = "```json\n{\"name\": \"Jane\", \"user[email]\": \"#{email}\"}\n```"

      expect(described_class.extract(raw)).to eq('name' => 'Jane', 'user[email]' => email)
    end

    it 'accepts scalar values that the operation stringifies' do
      expect(described_class.extract('{"apply": true, "salary": 3000, "comment": null}'))
        .to eq('apply' => true, 'salary' => 3000, 'comment' => nil)
    end

    it 'returns an empty hash for {} (the operation rejects it)' do
      expect(described_class.extract('{}')).to eq({})
    end

    it 'raises on nested values' do
      expect { described_class.extract('{"name": {"first": "Jane"}}') }.to raise_error(invalid)
    end

    it 'raises on a blank answer' do
      expect { described_class.extract('') }.to raise_error(invalid, 'blank AI response')
    end
  end

  it 'stays text-mode: dynamic keys cannot be a native schema' do
    expect(described_class.native_schema?).to be(false)
  end
end
