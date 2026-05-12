# frozen_string_literal: true

require "rails_helper"

RSpec.describe Proxy, type: :model do
  describe ".ready_for_use" do
    subject(:scope) { described_class.ready_for_use }

    # --- filtering ---

    context "last_used_at filtering" do
      it "includes proxy never used" do
        proxy = create(:proxy, last_used_at: nil)
        expect(scope).to include(proxy)
      end

      it "includes proxy used more than 5 seconds ago" do
        proxy = create(:proxy, last_used_at: 6.seconds.ago)
        expect(scope).to include(proxy)
      end

      it "excludes proxy used within last 5 seconds" do
        proxy = create(:proxy, last_used_at: 1.second.ago)
        expect(scope).not_to include(proxy)
      end
    end

    context "failed_at filtering" do
      it "includes proxy that never failed" do
        proxy = create(:proxy, failed_at: nil)
        expect(scope).to include(proxy)
      end

      it "includes proxy that failed more than 1 minute ago" do
        proxy = create(:proxy, failed_at: 61.seconds.ago)
        expect(scope).to include(proxy)
      end

      it "excludes proxy that failed within last 1 minute" do
        proxy = create(:proxy, failed_at: 30.seconds.ago)
        expect(scope).not_to include(proxy)
      end
    end

    # --- ordering ---

    context "ordering" do
      it "returns proxies with higher reliability ratio first" do
        low  = create(:proxy, success_count: 2, fail_count: 8)
        high = create(:proxy, success_count: 9, fail_count: 1)

        expect(scope.to_a).to eq([ high, low ])
      end

      it "treats never-used proxy as fully reliable" do
        never  = create(:proxy, success_count: 0, fail_count: 0)
        active = create(:proxy, success_count: 1, fail_count: 9)

        expect(scope.first).to eq(never)
      end

      it "treats all-success proxy as fully reliable" do
        perfect = create(:proxy, success_count: 5, fail_count: 0)
        mixed   = create(:proxy, success_count: 3, fail_count: 2)

        expect(scope.first).to eq(perfect)
      end

      it "puts lower-ratio proxy after higher-ratio proxy" do
        worse  = create(:proxy, success_count: 1, fail_count: 3)
        better = create(:proxy, success_count: 3, fail_count: 1)

        expect(scope.to_a).to eq([ better, worse ])
      end
    end
  end

  describe "#increment_succeeded!" do
    it "increments success_count" do
      proxy = create(:proxy, success_count: 3)
      proxy.increment_succeeded!
      expect(proxy.reload.success_count).to eq(4)
    end

    it "does not modify fail_count" do
      proxy = create(:proxy, fail_count: 2, failed_at: 2.minutes.ago)
      proxy.increment_succeeded!
      proxy.reload
      expect(proxy.fail_count).to eq(2)
    end
  end

  describe "#increment_fail!" do
    it "does not modify success_count" do
      proxy = create(:proxy, success_count: 5, fail_count: 0)
      proxy.increment_fail!
      expect(proxy.reload.success_count).to eq(5)
    end

    it "increments fail_count and sets failed_at" do
      proxy = create(:proxy, fail_count: 0, success_count: 10)
      proxy.increment_fail!
      proxy.reload
      expect(proxy.fail_count).to eq(1)
      expect(proxy.failed_at).to be_within(2.seconds).of(Time.current)
    end

    it "destroys the proxy when fail ratio reaches MAX_FAIL_RATIO" do
      proxy = create(:proxy, success_count: 1, fail_count: 2)
      proxy.increment_fail!
      expect(Proxy.exists?(proxy.id)).to be false
    end
  end
end
