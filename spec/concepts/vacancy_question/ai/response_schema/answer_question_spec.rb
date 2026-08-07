# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VacancyQuestion::Ai::ResponseSchema::AnswerQuestion do
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
      expect { described_class.extract('') }.to raise_error(/Failed to parse|Empty/)
    end

    it 'raises when the answer key is missing' do
      expect { described_class.extract('{"other": "value"}') }
        .to raise_error(/Failed to parse AI AnswerQuestion response/)
    end
  end
end
