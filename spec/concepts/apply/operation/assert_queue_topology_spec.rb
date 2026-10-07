# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::AssertQueueTopology, type: :operation do
  def stub_env(role:, slots:)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('SQ_ROLE', 'all').and_return(role)
    allow(ENV).to receive(:fetch).with('APPLY_SLOTS', '1').and_return(slots.to_s)
    allow(ENV).to receive(:fetch).with('APPLY_SLOTS').and_return(slots.to_s)
  end

  let(:role) { 'all' }
  let(:apply_worker) { { queues: [ 'apply' ], threads: 1, processes: 1 } }
  let(:general_worker) { { queues: [ 'default' ], threads: 2, processes: 2 } }

  describe 'real config/queue.yml' do
    %w[development test staging production].each do |env|
      %w[all general apply].each do |role|
        [ 1, 3 ].each do |slots|
          it "passes for #{env} / SQ_ROLE=#{role} / APPLY_SLOTS=#{slots}" do
            stub_env(role:, slots:)
            allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(env))

            workers = described_class.call.model
            queues = workers.map { |worker| worker[:queues] }

            expected = { 'all' => [ [ 'default' ], [ 'apply' ] ], 'general' => [ [ 'default' ] ], 'apply' => [ [ 'apply' ] ] }
            expect(queues).to eq(expected.fetch(role))

            apply = workers.find { |worker| worker[:queues] == [ 'apply' ] }
            expect(apply).to include(processes: 1, threads: slots) if apply
          end
        end
      end
    end

    %w[generl General].each do |bogus|
      it "fails rendering for SQ_ROLE=#{bogus} instead of starting both workers" do
        stub_env(role: bogus, slots: 1)

        expect { described_class.call }.to raise_error(described_class::Violation, /SQ_ROLE="#{bogus}" is not one of/)
      end
    end

    [ '0', 'three', '-1' ].each do |slots|
      it "fails rendering for APPLY_SLOTS=#{slots.inspect}" do
        stub_env(role: 'apply', slots:)

        expect { described_class.call }.to raise_error(described_class::Violation, /APPLY_SLOTS=.* positive integer/)
      end
    end

    it 'passes with no arguments for the current env' do
      result = described_class.call

      expect(result).to be_success
      expect(result.model.flat_map { |worker| worker[:queues] }).not_to include('*')
    end
  end

  describe 'violations' do
    before { stub_env(role:, slots: 1) }

    def call(workers)
      described_class.call(workers:)
    end

    it 'rejects a wildcard queue' do
      expect { call([ { queues: [ '*' ], threads: 2 }, apply_worker ]) }
        .to raise_error(described_class::Violation, /wildcard queue/)
    end

    it 'rejects two apply workers' do
      expect { call([ apply_worker, apply_worker.merge(threads: 2) ]) }
        .to raise_error(described_class::Violation, /2 workers serve the apply queue/)
    end

    it 'rejects apply threads different from APPLY_SLOTS' do
      expect { call([ general_worker, apply_worker.merge(threads: 5) ]) }
        .to raise_error(described_class::Violation, /threads must equal APPLY_SLOTS \(1\)/)
    end

    it 'rejects apply processes other than 1' do
      expect { call([ general_worker, apply_worker.merge(processes: 2) ]) }
        .to raise_error(described_class::Violation, /exactly 1 process/)
    end

    it 'accepts string keys and a bare queue string' do
      expect(call([ { 'queues' => 'apply', 'threads' => 1 }, general_worker ])).to be_success
    end

    context 'when role is apply and no apply worker exists' do
      let(:role) { 'apply' }

      it 'raises' do
        expect { call([ general_worker ]) }.to raise_error(described_class::Violation, /SQ_ROLE=apply requires/)
      end
    end

    context 'when role is unknown' do
      let(:role) { 'generl' }

      it 'raises even for a worker list that is otherwise valid' do
        expect { call([ general_worker ]) }.to raise_error(described_class::Violation, /SQ_ROLE="generl"/)
      end
    end

    context 'when role is apply and the primary pool cannot hold a heartbeat connection per thread' do
      let(:role) { 'apply' }

      before do
        stub_env(role:, slots: 3)
        allow(described_class).to receive(:primary_pool_size).and_return(7)
      end

      it 'raises with the 2 * APPLY_SLOTS + 2 requirement' do
        expect { call([ apply_worker.merge(threads: 3) ]) }
          .to raise_error(described_class::Violation, /pool of at least 8 \(2 \* APPLY_SLOTS \+ 2\), config has 7/)
      end

      it 'passes once the pool is large enough' do
        allow(described_class).to receive(:primary_pool_size).and_return(8)

        expect(call([ apply_worker.merge(threads: 3) ])).to be_success
      end
    end

    context 'when role is all with a small primary pool (puma runs the same boot check)' do
      before { allow(described_class).to receive(:primary_pool_size).and_return(3) }

      it 'does not check the pool' do
        expect(call([ general_worker, apply_worker ])).to be_success
      end
    end

    context 'when role is general and an apply worker exists' do
      let(:role) { 'general' }

      it 'raises' do
        expect { call([ general_worker, apply_worker ]) }
          .to raise_error(described_class::Violation, /SQ_ROLE=general must not serve/)
      end
    end
  end
end
