# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyQuestion::Ai::ResponseSchema::AnswerQuestion do
  let(:invalid) { ApplyMate::Ai::ResponseSchema::Json::InvalidResponse }

  describe '.extract' do
    it 'extracts the answer from a fenced json block' do
      raw = <<~RAW
        ```json
        { "answer": "Маю 8 років досвіду з Ruby." }
        ```
      RAW

      expect(described_class.extract(raw)).to eq('Маю 8 років досвіду з Ruby.')
    end

    it 'extracts the answer from bare json' do
      raw = '{"answer": "Так, маю досвід."}'

      expect(described_class.extract(raw)).to eq('Так, маю досвід.')
    end

    it 'raises on a blank response' do
      expect { described_class.extract('') }.to raise_error(invalid, 'blank AI response')
    end

    it 'raises when the answer key is missing' do
      expect { described_class.extract('{"other": "value"}') }.to raise_error(invalid, /answer/)
    end

    it 'raises on an empty answer' do
      expect { described_class.extract('{"answer": ""}') }.to raise_error(invalid, /answer/)
    end

    it 'raises on a whitespace-only answer' do
      expect { described_class.extract(%({"answer": " \\n\\t"})) }
        .to raise_error(invalid, 'AI AnswerQuestion response has no answer')
    end
  end
end
