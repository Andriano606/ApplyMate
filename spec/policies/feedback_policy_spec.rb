# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedbackPolicy do
  let(:feedback) { create(:feedback) }

  def policy(user)
    described_class.new(user, feedback)
  end

  it 'lets anyone read the index' do
    expect(described_class.new(nil, Feedback).index?).to be(true)
  end

  it 'lets only signed-in users create' do
    expect(described_class.new(create(:user), Feedback.new).create?).to be(true)
    expect(described_class.new(nil, Feedback.new).create?).to be(false)
  end

  it 'lets only the author update, even an admin cannot edit others' do
    expect(policy(feedback.user).update?).to be(true)
    expect(policy(create(:user, :admin)).update?).to be(false)
    expect(policy(create(:user)).update?).to be(false)
  end

  describe '#destroy?' do
    it 'allows the author and any admin' do
      expect(policy(feedback.user).destroy?).to be(true)
      expect(policy(create(:user, :admin)).destroy?).to be(true)
    end

    it 'denies other users and guests' do
      expect(policy(create(:user)).destroy?).to be(false)
      expect(policy(nil).destroy?).to be(false)
    end
  end
end
