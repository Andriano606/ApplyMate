# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AnswerBank do
  it 'is valid for a role answer' do
    expect(build(:answer_bank)).to be_valid
  end

  it 'requires role and answer' do
    expect(build(:answer_bank, role: nil)).not_to be_valid
    expect(build(:answer_bank, answer: '')).not_to be_valid
  end

  it 'requires question for custom_question entries' do
    expect(build(:answer_bank, :custom, question: nil)).not_to be_valid
    expect(build(:answer_bank, :custom)).to be_valid
  end

  describe '.normalize_question' do
    it 'downcases and squishes whitespace' do
      expect(described_class.normalize_question("  How  MANY years\nof React? "))
        .to eq('how many years of react?')
    end
  end
end
