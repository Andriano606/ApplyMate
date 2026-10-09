# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Ai::Request do
  describe '.for' do
    {
      navigate: [ 1_024, 1_024, 60 ],
      answers:  [ 4_096, 2_048, 90 ],
      verify:   [ 512, 512, 30 ],
      cv:       [ 8_192, 2_048, 180 ]
    }.each do |kind, (max_output_tokens, thinking_budget, timeout)|
      it "sizes a #{kind} request to #{max_output_tokens} + #{thinking_budget} thinking tokens / #{timeout}s" do
        request = described_class.for(kind:, text: 'hi')

        expect(request).to have_attributes(max_output_tokens:, thinking_budget:, timeout:,
                                           output_token_limit: max_output_tokens + thinking_budget)
      end
    end

    it 'wraps the text as a single user message with no system, images or schema by default' do
      request = described_class.for(kind: :answers, text: 'Fill the form')

      expect(request).to have_attributes(
        messages:    [ { role: 'user', content: 'Fill the form' } ],
        system:      nil,
        images:      [],
        json_schema: nil
      )
    end

    it 'passes system, images and json_schema through' do
      schema = { type: 'object' }
      image  = { mime_type: 'image/png', data: 'aGk=' }
      request = described_class.for(kind: :verify, text: 'x', system: 'Be brief', images: [ image ], json_schema: schema)

      expect(request).to have_attributes(system: 'Be brief', images: [ image ], json_schema: schema)
    end

    {
      navigate: 0, answers: 2, verify: 0, cv: 2
    }.each do |kind, retries|
      it "retries a #{kind} request #{retries} time(s) by default" do
        expect(described_class.for(kind:, text: 'hi').retries).to eq(retries)
      end
    end

    it 'takes timeout and retries overrides, nil meaning the kind default' do
      expect(described_class.for(kind: :answers, text: 'x', timeout: 12, retries: 0)).to have_attributes(timeout: 12, retries: 0)
      expect(described_class.for(kind: :answers, text: 'x', timeout: nil, retries: nil)).to have_attributes(timeout: 90, retries: 2)
    end

    it 'covers every declared kind in both tables' do
      expect(described_class::MAX_OUTPUT_TOKENS.keys).to eq(described_class::KINDS)
      expect(described_class::TIMEOUTS.keys).to eq(described_class::KINDS)
      expect(described_class::THINKING_BUDGETS.keys).to eq(described_class::KINDS)
      expect(described_class::RETRIES.keys).to eq(described_class::KINDS)
    end

    it 'raises KeyError on an unknown kind' do
      expect { described_class.for(kind: :chat, text: 'hi') }.to raise_error(KeyError)
    end
  end

  it 'is immutable' do
    expect(described_class.for(kind: :cv, text: 'x')).to be_frozen
  end
end
