# frozen_string_literal: true

require "rails_helper"

RSpec.describe Proxy::Operation::PruneProxies, type: :operation do
  subject(:perform) { described_class.call }

  let(:source) { create(:source) }
  let(:old)    { (described_class::PRUNE_AFTER + 1.day).ago }

  let!(:old_untested) { create(:proxy, created_at: old) }
  let!(:old_dead)     { create(:proxy, created_at: old) }
  let!(:old_working)  { create(:proxy, created_at: old) }
  let!(:new_untested) { create(:proxy) }

  before do
    create(:proxy_source_stat, proxy: old_dead, source:, success_count: 0, fail_count: 4, reliability: 0.0)
    create(:proxy_source_stat, proxy: old_working, source:, success_count: 2, fail_count: 5)
  end

  it "deletes old proxies that do not work for any source, with their stats" do
    expect(perform.model).to eq(2)

    expect(Proxy.where(id: [ old_untested.id, old_dead.id ])).to be_empty
    expect(ProxySourceStat.where(proxy_id: old_dead.id)).to be_empty
  end

  it "keeps working and recently inserted proxies" do
    perform

    expect(Proxy.where(id: [ old_working.id, new_untested.id ]).count).to eq(2)
  end
end
