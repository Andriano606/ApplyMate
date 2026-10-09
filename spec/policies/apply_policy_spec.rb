# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyPolicy do
  let(:user)  { create(:user) }
  let(:apply) { create(:apply, user:) }

  %i[resume? cancel? mark_outcome? approve_review? provide_input?].each do |query|
    describe "##{query}" do
      it 'is allowed for the owner' do
        expect(described_class.new(user, apply).public_send(query)).to be(true)
      end

      it 'is denied for another user' do
        expect(described_class.new(create(:user), apply).public_send(query)).to be(false)
      end

      it 'is denied without a user' do
        expect(described_class.new(nil, apply).public_send(query)).to be(false)
      end
    end
  end
end
