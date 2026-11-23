# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FeedbackReplyPolicy do
  let(:feedback) { create(:feedback) }
  let(:reply)    { FeedbackReply.new(feedback:) }

  def permitted?(user)
    described_class.new(user, reply).create?
  end

  it 'lets an admin reply under any review' do
    expect(permitted?(create(:user, :admin))).to be(true)
  end

  it 'lets the author reply under their own review' do
    expect(permitted?(feedback.user)).to be(true)
  end

  it 'denies another regular user' do
    expect(permitted?(create(:user))).to be(false)
  end

  it 'denies a guest' do
    expect(permitted?(nil)).to be(false)
  end
end
