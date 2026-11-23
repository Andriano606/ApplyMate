# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedbackThreadRead do
  let(:user)     { create(:user) }
  let(:feedback) { create(:feedback) }

  describe '.mark_seen!' do
    it 'creates one mark per user and thread' do
      time = 2.hours.ago

      expect { described_class.mark_seen!(user, { feedback.id => time }) }.to change(described_class, :count).by(1)

      expect(described_class.find_by!(user:, feedback:).seen_at).to be_within(1.second).of(time)
    end

    it 'moves the mark forward' do
      described_class.mark_seen!(user, { feedback.id => 2.hours.ago })
      newer = 1.hour.ago

      described_class.mark_seen!(user, { feedback.id => newer })

      expect(described_class.where(user:, feedback:).pluck(:seen_at)).to match([ be_within(1.second).of(newer) ])
    end

    it 'never moves the mark backwards' do
      newer = 1.hour.ago
      described_class.mark_seen!(user, { feedback.id => newer })

      described_class.mark_seen!(user, { feedback.id => 5.hours.ago })

      expect(described_class.find_by!(user:, feedback:).seen_at).to be_within(1.second).of(newer)
    end

    it 'marks several threads at once and ignores an empty hash' do
      other = create(:feedback)

      expect { described_class.mark_seen!(user, { feedback.id => 1.hour.ago, other.id => 2.hours.ago }) }
        .to change(described_class, :count).by(2)
      expect { described_class.mark_seen!(user, {}) }.not_to change(described_class, :count)
    end
  end
end
