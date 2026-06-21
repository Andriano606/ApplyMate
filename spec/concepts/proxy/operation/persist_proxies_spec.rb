# frozen_string_literal: true

require "rails_helper"

RSpec.describe Proxy::Operation::PersistProxies, type: :operation do
  subject(:perform) { described_class.call(proxies:) }

  let(:proxies) { [] }

  def proxy_attrs(host:, port: 8080, protocol: "http")
    { host:, port:, protocol: }
  end

  context "with no proxies" do
    it "is a no-op and returns 0" do
      expect { perform }.not_to change(Proxy, :count)
      expect(perform.model).to eq(0)
    end
  end

  context "with brand-new proxies" do
    let(:now) { Time.utc(2026, 6, 5, 12, 0, 0) }
    let(:proxies) { [ proxy_attrs(host: "1.1.1.1") ] }

    it "inserts them with the current time as created_at and updated_at" do
      travel_to(now) do
        expect { perform }.to change(Proxy, :count).by(1)
      end

      proxy = Proxy.find_by(host: "1.1.1.1", port: 8080, protocol: "http")
      expect(proxy.created_at).to eq(now)
      expect(proxy.updated_at).to eq(now)
    end

    it "returns the number of persisted records" do
      expect(perform.model).to eq(1)
    end
  end

  context "with proxies that already exist" do
    let(:original_time) { Time.utc(2026, 1, 1, 0, 0, 0) }
    let(:proxies) { [ proxy_attrs(host: "2.2.2.2") ] }

    let!(:existing) do
      travel_to(original_time) do
        create(:proxy, host: "2.2.2.2", port: 8080, protocol: "http")
      end
    end

    it "does not insert a duplicate row" do
      expect { perform }.not_to change(Proxy, :count)
    end

    it "leaves created_at and updated_at untouched" do
      travel_to(original_time + 5.days) { perform }

      existing.reload
      expect(existing.created_at).to eq(original_time)
      expect(existing.updated_at).to eq(original_time)
    end
  end

  context "with a mix of new and existing proxies" do
    let(:original_time) { Time.utc(2026, 1, 1, 0, 0, 0) }
    let(:insert_time)   { Time.utc(2026, 6, 5, 12, 0, 0) }
    let(:proxies) do
      [
        proxy_attrs(host: "2.2.2.2"), # existing
        proxy_attrs(host: "3.3.3.3")  # new
      ]
    end

    let!(:existing) do
      travel_to(original_time) do
        create(:proxy, host: "2.2.2.2", port: 8080, protocol: "http")
      end
    end

    it "inserts only the new proxy and preserves the existing one's timestamps" do
      travel_to(insert_time) do
        expect { perform }.to change(Proxy, :count).by(1)
      end

      existing.reload
      expect(existing.created_at).to eq(original_time)
      expect(existing.updated_at).to eq(original_time)

      inserted = Proxy.find_by(host: "3.3.3.3")
      expect(inserted.created_at).to eq(insert_time)
      expect(inserted.updated_at).to eq(insert_time)
    end
  end

  context "when the same proxy differs only by protocol" do
    let(:proxies) do
      [
        proxy_attrs(host: "4.4.4.4", port: 1080, protocol: "http"),
        proxy_attrs(host: "4.4.4.4", port: 1080, protocol: "socks5")
      ]
    end

    it "treats them as distinct records" do
      expect { perform }.to change(Proxy, :count).by(2)
    end
  end
end
