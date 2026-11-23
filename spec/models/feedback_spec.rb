# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Feedback do
  subject(:feedback) { build(:feedback) }

  it { is_expected.to be_valid }

  describe 'validations' do
    it 'requires a rating between 1 and 10' do
      [ 0, 11, nil ].each do |rating|
        feedback.rating = rating
        expect(feedback).not_to be_valid
        expect(feedback.errors[:rating]).to be_present
      end
      [ 1, 10 ].each do |rating|
        feedback.rating = rating
        expect(feedback).to be_valid
      end
    end

    it 'requires a body of at most 2000 characters' do
      feedback.body = ''
      expect(feedback).not_to be_valid

      feedback.body = 'a' * 2001
      expect(feedback).not_to be_valid

      feedback.body = 'a' * 2000
      expect(feedback).to be_valid
    end

    it 'accepts only web or mcp as the source' do
      feedback.posted_via = 'email'
      expect(feedback).not_to be_valid

      feedback.posted_via = 'mcp'
      expect(feedback).to be_valid
    end

    it 'allows one feedback per user' do
      user = create(:user)
      create(:feedback, user:)

      duplicate = build(:feedback, user:)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:base]).to include(I18n.t('feedback.errors.already_exists'))
    end

    it 'lets an existing feedback be updated' do
      saved = create(:feedback)

      expect(saved.update(rating: 3)).to be(true)
    end
  end

  describe 'sentiment' do
    {
      1 => :negative, 4 => :negative, 5 => :neutral, 6 => :neutral, 7 => :positive, 10 => :positive
    }.each do |rating, sentiment|
      it "maps rating #{rating} to #{sentiment}" do
        expect(build(:feedback, rating:).sentiment).to eq(sentiment)
      end
    end

    it 'filters by sentiment with .with_sentiment' do
      positive = create(:feedback, rating: 9)
      neutral  = create(:feedback, rating: 5)
      negative = create(:feedback, rating: 2)

      expect(described_class.with_sentiment(:positive)).to contain_exactly(positive)
      expect(described_class.with_sentiment(:neutral)).to contain_exactly(neutral)
      expect(described_class.with_sentiment(:negative)).to contain_exactly(negative)
    end
  end

  describe '#edited?' do
    it 'is false right after posting and true once edited later' do
      saved = create(:feedback)
      expect(saved).not_to be_edited

      saved.update_columns(updated_at: saved.created_at + 2.minutes)
      expect(saved).to be_edited
    end
  end
end
