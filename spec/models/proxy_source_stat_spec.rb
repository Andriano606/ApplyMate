# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProxySourceStat do
  describe '.reliability_for' do
    it 'is the success ratio for tested proxies' do
      expect(described_class.reliability_for(3, 1)).to eq(0.75)
      expect(described_class.reliability_for(0, 2)).to eq(0.0)
    end

    it 'is 1.0 (optimistic) when untested' do
      expect(described_class.reliability_for(0, 0)).to eq(1.0)
    end
  end

  describe '.ready_for_use' do
    let(:source) { create(:source) }

    it 'excludes proxies still in post-failure cooldown' do
      fresh    = create(:proxy_source_stat, source: source, failed_at: nil)
      cooling  = create(:proxy_source_stat, source: source, failed_at: 30.seconds.ago)
      recovered = create(:proxy_source_stat, source: source, failed_at: 5.minutes.ago)

      ids = described_class.ready_for_use.pluck(:id)
      expect(ids).to include(fresh.id, recovered.id)
      expect(ids).not_to include(cooling.id)
    end
  end
end
