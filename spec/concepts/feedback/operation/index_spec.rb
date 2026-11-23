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
    expect(model.viewer).to be_nil
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

  context 'as a guest' do
    it 'has no new replies' do
      expect(model.new_reply_ids).to eq([])
    end
  end

  context 'when signed in' do
    let(:current_user) { positive.user }

    it "returns the viewer's own review separately and leaves it out of the list" do
      expect(model.viewer).to eq(current_user)
      expect(model.own_feedback).to eq(positive)
      expect(model.feedbacks).to eq([ negative, neutral ])
    end

    it 'keeps the stats over every review, own one included' do
      expect(model.stats[:total]).to eq(3)
    end

    it 'applies the sentiment filter to the list only' do
      filtered = described_class.new(params: ActionController::Parameters.new(sentiment: 'positive'), current_user:)
                                .tap(&:call).result.model

      expect(filtered.feedbacks.to_a).to be_empty
      expect(filtered.own_feedback).to eq(positive)
    end

    context 'with unread replies under the own review' do
      let(:admin) { create(:user, :admin) }
      let!(:old_reply) { create(:feedback_reply, feedback: positive, user: admin, created_at: 2.hours.ago) }
      let!(:new_reply) { create(:feedback_reply, feedback: positive, user: admin, created_at: 1.hour.ago) }

      it 'returns their ids and marks them seen' do
        expect(model.new_reply_ids).to contain_exactly(old_reply.id, new_reply.id)
        mark = FeedbackThreadRead.find_by!(user: current_user, feedback: positive)
        expect(mark.seen_at).to be_within(1.second).of(new_reply.created_at)
        expect(current_user.unread_feedback_reply_count).to eq(0)
      end

      it 'reports nothing new on the next visit' do
        result
        again = described_class.new(params:, current_user:).tap(&:call).result.model

        expect(again.new_reply_ids).to eq([])
      end
    end

    it 'has no new replies when the thread is quiet' do
      expect(model.new_reply_ids).to eq([])
    end

    it 'preloads the replies of the listed reviews' do
      create(:feedback_reply, feedback: negative)

      expect(model.feedbacks.first.association(:replies)).to be_loaded
    end

    it 'has no own review for a user who never posted' do
      operation = described_class.new(params:, current_user: create(:user)).tap(&:call)

      expect(operation.result.model.own_feedback).to be_nil
      expect(operation.result.model.viewer).to be_present
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

  describe 'unread replies' do
    let(:admin)        { create(:user, :admin) }
    let(:current_user) { create(:user) }
    let!(:mine)        { create(:feedback, user: current_user) }

    it 'counts threads with unread replies for the badge and pill' do
      create(:feedback_reply, feedback: mine, user: admin)
      create(:feedback_reply, feedback: mine, user: admin)

      expect(model.unread_threads).to eq(1)
    end

    it 'with unread=1 lists only the threads with unread replies the viewer takes part in' do
      replied = create(:feedback)
      FeedbackThreadRead.mark_seen!(current_user, { replied.id => 3.hours.ago })
      create(:feedback_reply, feedback: replied, user: admin)
      create(:feedback_reply, feedback: negative, user: admin) # viewer not a participant

      filtered = described_class.new(params: ActionController::Parameters.new(unread: '1'), current_user:)
                                .tap(&:call).result.model

      expect(filtered.unread).to be(true)
      expect(filtered.feedbacks.to_a).to eq([ replied ])
      expect(filtered.feedbacks.total_entries).to eq(1)
      expect(filtered.unread_threads).to eq(1)
    end

    it 'ignores unread=1 for a guest' do
      guest = described_class.new(params: ActionController::Parameters.new(unread: '1'), current_user: nil)
                             .tap(&:call).result.model

      expect(guest.unread).to be(false)
      expect(guest.unread_threads).to eq(0)
      expect(guest.feedbacks.to_a.size).to eq(4)
    end

    it 'marks the own thread and every listed thread read, but still returns them for the filtered page' do
      replied = create(:feedback)
      FeedbackThreadRead.mark_seen!(current_user, { replied.id => 3.hours.ago })
      own_reply = create(:feedback_reply, feedback: mine, user: admin)
      other_reply = create(:feedback_reply, feedback: replied, user: admin)

      filtered = described_class.new(params: ActionController::Parameters.new(unread: '1'), current_user:)
                                .tap(&:call).result.model

      expect(filtered.new_reply_ids).to contain_exactly(own_reply.id, other_reply.id)
      expect(current_user.unread_feedback_reply_count).to eq(0)
      again = described_class.new(params: ActionController::Parameters.new(unread: '1'), current_user:)
                             .tap(&:call).result.model
      expect(again.feedbacks.to_a).to be_empty
    end

    it 'does not mark threads that are not on the page' do
      replied = create(:feedback)
      FeedbackThreadRead.mark_seen!(current_user, { replied.id => 3.hours.ago })
      create(:feedback_reply, feedback: replied, user: admin)
      stub_const('Feedback::Operation::Index::PER_PAGE', 1)
      newer = create(:feedback, updated_at: 1.minute.from_now)

      result = described_class.new(params:, current_user:).tap(&:call).result.model

      expect(result.feedbacks.to_a).to eq([ newer ])
      expect(current_user.unread_feedback_reply_count).to eq(1)
    end
  end
end
