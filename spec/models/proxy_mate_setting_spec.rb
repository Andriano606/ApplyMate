# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProxyMateSetting do
  describe '.instance' do
    it 'returns the same single row on every call' do
      expect(described_class.instance).to eq(described_class.instance)
      expect(described_class.count).to eq(1)
    end

    it 'adopts the row a concurrent first-save inserted' do
      winner = described_class.create!
      allow(described_class).to receive(:first).and_return(nil, winner)
      allow(described_class).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

      expect(described_class.instance).to eq(winner)
    end
  end

  it 'cannot hold two rows (unique index on the constant column)' do
    described_class.create!

    expect { described_class.create! }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  describe '#api_key_preview' do
    it 'is nil without a key and the first 9 characters with one' do
      expect(described_class.new.api_key_preview).to be_nil
      expect(described_class.new(api_key: 'pm_AbCdEfGhIj').api_key_preview).to eq('pm_AbCdEf…')
    end
  end
end
