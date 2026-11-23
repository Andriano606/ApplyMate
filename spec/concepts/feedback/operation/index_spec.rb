# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Feedback::Operation::Index, type: :operation do
  let(:params) { ActionController::Parameters.new }

  let!(:positive) { create(:feedback, rating: 10, updated_at: 3.days.ago) }
  let!(:neutral)  { create(:feedback, rating: 5, updated_at: 2.days.ago) }
  let!(:negative) { create(:feedback, rating: 2, updated_at: 1.day.ago) }

  it 'is public: a guest sees every review, newest edit first' do
    expect(result).to be_success
    expect(model.feedbacks).to eq([ negative, neutral, positive ])
    expect(model.signed_in).to be(false)
    expect(model.own_feedback).to be_nil
    expect(model.sentiment).to be_nil
  end

  it 'summarises total, average and the sentiment split' do
    expect(model.stats).to eq(total: 3, average: 5.7, by_sentiment: { positive: 1, neutral: 1, negative: 1 })
  end

  context 'without any feedback' do
    before { Feedback.delete_all }

    it 'has no average' do
      expect(model.stats).to eq(total: 0, average: nil, by_sentiment: { positive: 0, neutral: 0, negative: 0 })
    end
  end

  %i[positive neutral negative].each do |sentiment|
    context "with sentiment=#{sentiment}" do
      let(:params)   { ActionController::Parameters.new(sentiment:) }
      let(:expected) { { positive:, neutral:, negative: }.fetch(sentiment) }

      it 'lists only those reviews but keeps the overall stats' do
        expect(model.feedbacks).to eq([ expected ])
        expect(model.sentiment).to eq(sentiment)
        expect(model.stats[:total]).to eq(3)
      end
    end
  end

  context 'with an unknown sentiment' do
    let(:params) { ActionController::Parameters.new(sentiment: 'bogus') }

    it 'falls back to all reviews' do
      expect(model.sentiment).to be_nil
      expect(model.feedbacks.to_a.size).to eq(3)
    end
  end

  context 'when signed in' do
    let(:current_user) { positive.user }

    it "returns the viewer's own review" do
      expect(model.signed_in).to be(true)
      expect(model.own_feedback).to eq(positive)
    end

    it 'has no own review for a user who never posted' do
      operation = described_class.new(params:, current_user: create(:user)).tap(&:call)

      expect(operation.result.model.own_feedback).to be_nil
      expect(operation.result.model.signed_in).to be(true)
    end
  end

  context 'with more than one page' do
    before do
      create_list(:feedback, 20) do |feedback, i|
        feedback.update_columns(updated_at: 10.days.ago - i.minutes)
      end
    end

    it 'paginates by 20' do
      expect(model.feedbacks.to_a.size).to eq(20)
      expect(model.feedbacks.total_entries).to eq(23)
    end

    it 'serves the next page' do
      page_two = described_class.new(params: ActionController::Parameters.new(page: 2), current_user: nil)
                                .tap(&:call).result.model

      expect(page_two.feedbacks.to_a.size).to eq(3)
    end
  end
end
