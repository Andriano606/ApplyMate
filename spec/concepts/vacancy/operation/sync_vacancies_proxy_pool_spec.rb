# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Vacancy::Operation::SyncVacancies::ProxyPool do
  let(:source)     { create(:source, name: 'Djinni', base_url: 'https://djinni.co', scraper: 'ApplyMate::Scraper::Djinni') }
  let(:proxy_mate) { instance_double(ApplyMate::Client::ProxyMate) }
  let(:pool)       { described_class.new(source, proxy_mate, session_id: 1, impersonate_targets: %w[chrome146 firefox147]) }
  let(:proxy)      { proxy_row(7) }
  let(:clock)      { [ 1_000.0 ] }
  let(:queries)    { [] }
  let(:batches)    { [ [ proxy ] ] } # what ProxyMate answers, in order; then [] with remaining: 0

  def proxy_row(id)
    ApplyMate::Client::ProxyMate::Proxy.new(id: id, url: "http://10.0.0.#{id}:8080", protocol: 'http', clearance: nil)
  end

  def batch(proxies, remaining: 0)
    ApplyMate::Client::ProxyMate::Batch.new(proxies: proxies, available: proxies.size + remaining, remaining: remaining)
  end

  before do
    stub_const("#{described_class}::REFILL_INTERVAL", 0)
    allow(pool).to receive(:monotonic) { clock[0] }
    allow(proxy_mate).to receive(:proxies) do |**query|
      queries << query
      next_batch = batches.shift
      next_batch.is_a?(ApplyMate::Client::ProxyMate::Batch) ? next_batch : batch(next_batch || [])
    end
  end

  # One request through the pool's next proxy; `wait` seconds pass after it.
  def use(wait: described_class::USE_INTERVAL, ok: true)
    taken = pool.acquire
    pool.release(taken, ok: ok)
    clock[0] += wait
    taken
  end

  # Every proxy the pool hands out until none is ready, each released with `ok`.
  def drain_round(ok: false)
    taken = []
    while (proxy = pool.acquire)
      taken << proxy
      pool.release(proxy, ok: ok)
    end
    taken
  end

  def rounds_started(events)
    events.select { |e| e['event'] == 'vacancy_sync_proxy_round_started' }
  end

  describe 'the ProxyMate session' do
    it 'asks in one session per run and source, with fields=minimal and no exclude list' do
      pool.seed!

      expect(queries.first).to eq(site: 'djinni', order: 'stable', protocols: ApplyMate::Client::ImpersonateHttp.supported_proxy_protocols,
                                  cloudflare: 'any', session_id: "applymate-1-#{source.id}", limit: described_class::SEED_BATCH,
                                  impersonate_targets: %w[chrome146 firefox147])
      expect(pool.proxy_session).to match(/\A[\w.:-]{1,100}\z/)
    end
  end

  describe 'the use limit' do
    before { pool.seed! }

    it 'retires a proxy after MAX_USES uses' do
      described_class::MAX_USES.times { expect(use).to eq(proxy) }

      expect(pool.size).to eq(0)
      expect(pool.take_counts!).to include(retired_proxies: 1, proxy_rounds: 1)
    end

    it 'keeps USE_INTERVAL seconds between two uses of a proxy' do
      use(wait: described_class::USE_INTERVAL - 1)
      expect(pool.acquire).to be_nil

      clock[0] += 1
      expect(pool.acquire).to eq(proxy)
    end

    it 'counts a failed request as a use' do
      other = proxy_row(8)
      (described_class::MAX_USES - 1).times { use }
      pool.drop(pool.acquire)
      batches.push([ proxy, other ]) # were ProxyMate to hand proxy 7 out again in this round

      clock[0] += described_class::USE_INTERVAL
      expect(pool.acquire).to eq(other)
      expect(pool.acquire).to be_nil
    end
  end

  describe 'refills' do
    before { pool.seed! }

    it 'does not end the round while proxies are only cooling down, even when ProxyMate has nothing left' do
      events = capture_logged_events
      use(wait: 1)

      expect(pool.acquire).to be_nil # refill: nothing, remaining 0 — but proxy 7 is still in the pool
      expect(rounds_started(events)).to be_empty
      expect(pool).not_to be_exhausted
    end

    it 'adds what ProxyMate gives while the pool still has proxies' do
      fresh = proxy_row(8)
      batches.push([ fresh ])
      use(wait: 1)

      expect(pool.acquire).to eq(fresh)
    end
  end

  describe 'rounds' do
    let(:old)     { proxy_row(1) }
    let(:middle)  { proxy_row(2) }
    let(:recent)  { proxy_row(3) }
    let(:batches) { [ [ old, middle, recent ] ] }

    before { pool.seed! }

    # Takes the next proxy (expected to be `expected`), uses it once and lets `wait` seconds
    # pass; `dead` = it fails as a proxy.
    def take(expected, dead: false, wait: 1)
      taken = pool.acquire
      expect(taken).to eq(expected)
      dead ? pool.drop(taken) : pool.release(taken)
      clock[0] += wait
    end

    it 'starts a new round once the pool is empty and ProxyMate has nothing new, bringing back dead and retired proxies' do
      stub_const("#{described_class}::MAX_USES", 1)
      events = capture_logged_events
      take(old, dead: true)
      take(middle) # retired after its one use
      take(recent, dead: true)
      clock[0] += described_class::USE_INTERVAL

      expect(drain_round(ok: true)).to eq([ old, middle, recent ]) # the refill got nothing, remaining: 0 → round 2
      expect(rounds_started(events).first)
        .to include('session_id' => 1, 'source' => 'Djinni', 'round' => 2, 'proxies' => 3, 'level' => 'info')
    end

    it 'hands the proxies out least recently used first, each USE_INTERVAL after its last use' do
      stub_const("#{described_class}::MAX_USES", 1)
      take(old, dead: true, wait: 10)    # last use at t = 1000
      take(middle, wait: 10)             # t = 1010
      take(recent, dead: true, wait: 10) # t = 1020; now t = 1030

      expect(pool.acquire).to be_nil # round 2 has started, but no proxy has rested USE_INTERVAL yet
      clock[0] = 1_000.0 + described_class::USE_INTERVAL
      expect(pool.acquire).to eq(old)
      expect(pool.acquire).to be_nil
      clock[0] += 20
      expect([ pool.acquire, pool.acquire ]).to eq([ middle, recent ])
    end

    it 'gives every proxy MAX_USES uses again in the new round' do
      stub_const("#{described_class}::MAX_USES", 2)

      2.times do # round 1: two uses each → all retired
        [ old, middle, recent ].each { |expected| take(expected) }
        clock[0] += described_class::USE_INTERVAL
      end
      expect(pool.size).to eq(0)

      2.times do # round 2: two uses each again
        [ old, middle, recent ].each { |expected| take(expected) }
        clock[0] += described_class::USE_INTERVAL
      end
      expect(pool.take_counts!).to include(retired_proxies: 6, proxy_rounds: 2)
    end

    it 'keeps adding what ProxyMate gives in a later round' do
      stub_const("#{described_class}::MAX_USES", 1)
      expect(drain_round(ok: true)).to eq([ old, middle, recent ]) # its last acquire started round 2
      clock[0] += described_class::USE_INTERVAL

      fresh = proxy_row(9)
      batches.push([ fresh ])
      expect(drain_round(ok: true)).to eq([ old, middle, recent, fresh ])
    end

    context 'when requests do not succeed' do
      before { stub_const("#{described_class}::MAX_USES", 1) }

      it 'is drained after MAX_EMPTY_ROUNDS rounds in a row without a successful use' do
        events = capture_logged_events

        expect(drain_round(ok: false).size).to eq(3) # round 1; its end starts round 2
        expect(pool).not_to be_exhausted
        clock[0] += described_class::USE_INTERVAL
        expect(drain_round(ok: false).size).to eq(3) # round 2; its end drains the pool

        expect(pool).to be_exhausted
        expect(rounds_started(events).pluck('round')).to eq([ 2 ])
      end

      it 'is not drained after a round with one successful use, only after MAX_EMPTY_ROUNDS empty ones after it' do
        drain_round(ok: false) # round 1: no success
        clock[0] += described_class::USE_INTERVAL
        pool.release(pool.acquire) # round 2: one success…
        drain_round(ok: false)     # …the rest fail; round 3 starts

        expect(pool).not_to be_exhausted
        clock[0] += described_class::USE_INTERVAL
        drain_round(ok: false) # round 3: no success; round 4 starts
        expect(pool).not_to be_exhausted
        clock[0] += described_class::USE_INTERVAL
        drain_round(ok: false) # round 4: no success either → drained

        expect(pool).to be_exhausted
        expect(pool.take_counts!).to include(proxy_rounds: 4)
      end

      it 'counts the normal release as a success and a release with ok: false as none' do
        drain_round(ok: false) # round 1
        clock[0] += described_class::USE_INTERVAL
        drain_round(ok: true)  # round 2: three successes
        clock[0] += described_class::USE_INTERVAL
        drain_round(ok: false) # round 3

        expect(pool).not_to be_exhausted
        expect(pool.take_counts!).to include(proxy_rounds: 4)
      end
    end
  end

  describe 'termination' do
    it 'is drained when the seed brings no proxy at all' do
      batches.replace([ [] ])
      pool.seed!

      expect(pool.acquire).to be_nil
      expect(pool).to be_exhausted
      expect(queries.size).to eq(1) # no refill after a drained seed
    end

    it 'ends the round after MAX_REFILL_FAILURES fruitless refills even if ProxyMate claims more remain' do
      pool.seed!
      events = capture_logged_events
      # +1: the acquire before the drop refills too (only one proxy is ready)
      batches.replace(Array.new(described_class::MAX_REFILL_FAILURES + 1) { batch([], remaining: 5) })
      pool.drop(pool.acquire)

      (described_class::MAX_REFILL_FAILURES - 1).times { expect(pool.acquire).to be_nil }
      expect(rounds_started(events)).to be_empty
      pool.acquire
      expect(rounds_started(events).size).to eq(1)
    end

    it 'counts a batch of only used-up proxies as fruitless' do
      pool.seed!
      events = capture_logged_events
      described_class::MAX_USES.times { use } # proxy 7 retired
      batches.replace(Array.new(described_class::MAX_REFILL_FAILURES) { batch([ proxy ], remaining: 1) })

      described_class::MAX_REFILL_FAILURES.times { pool.acquire }

      expect(rounds_started(events).size).to eq(1)
    end

    it 'ends rounds after MAX_REFILL_FAILURES failed refills in a row, and drains when none succeeds' do
      pool.seed!
      allow(proxy_mate).to receive(:proxies).and_raise(ApplyMate::Client::ProxyMate::RequestError, 'down')
      pool.drop(pool.acquire)

      described_class::MAX_REFILL_FAILURES.times { pool.acquire } # → round 2, proxy 7 back
      clock[0] += described_class::USE_INTERVAL
      pool.drop(pool.acquire)
      expect(pool).not_to be_exhausted
      described_class::MAX_REFILL_FAILURES.times { pool.acquire }

      expect(pool).to be_exhausted
    end
  end
end
