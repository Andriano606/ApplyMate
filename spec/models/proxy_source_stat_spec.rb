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

  describe '.apply_deltas!' do
    let(:source) { create(:source) }
    let(:proxy)  { create(:proxy) }

    def delta(success: 0, fail: 0, failed_at: nil)
      {
        proxy_id:      proxy.id,
        source_id:     source.id,
        success_count: success,
        fail_count:    fail,
        failed_at:     failed_at,
        reliability:   described_class.reliability_for(success, fail)
      }
    end

    it 'inserts a new row from the delta' do
      described_class.apply_deltas!([ delta(success: 2) ])

      stat = described_class.find_by(proxy: proxy, source: source)
      expect(stat).to have_attributes(success_count: 2, fail_count: 0, reliability: 1.0)
    end

    it 'adds to the existing totals instead of overwriting them' do
      create(:proxy_source_stat, proxy: proxy, source: source, success_count: 8, fail_count: 2)

      described_class.apply_deltas!([ delta(success: 2) ])

      stat = described_class.find_by(proxy: proxy, source: source)
      expect(stat.success_count).to eq(10)
      expect(stat.fail_count).to eq(2)
      expect(stat.reliability).to be_within(0.001).of(10.0 / 12)
    end

    it 'accumulates across separate calls (concurrent writers do not clobber)' do
      described_class.apply_deltas!([ delta(success: 1) ])
      described_class.apply_deltas!([ delta(fail: 1, failed_at: Time.current) ])

      stat = described_class.find_by(proxy: proxy, source: source)
      expect(stat).to have_attributes(success_count: 1, fail_count: 1)
      expect(stat.failed_at).to be_present
      expect(stat.reliability).to be_within(0.001).of(0.5)
    end

    it 'keeps an earlier failed_at when the delta carries none' do
      failed = 2.minutes.ago
      described_class.apply_deltas!([ delta(fail: 1, failed_at: failed) ])
      described_class.apply_deltas!([ delta(success: 1) ])

      expect(described_class.find_by(proxy: proxy, source: source).failed_at).to be_within(1.second).of(failed)
    end

    it 'is a no-op for an empty list' do
      expect { described_class.apply_deltas!([]) }.not_to change(described_class, :count)
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
