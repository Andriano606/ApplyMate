# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplyMate::Client::BrowserProfile do
  let(:name) { "spec_#{SecureRandom.hex(4)}" }

  after { described_class.clear(name) }

  describe '.acquire' do
    it 'hands out a directory that survives between calls' do
      first = described_class.acquire(name)
      path  = first.path
      first.release

      second = described_class.acquire(name)
      expect(second.path).to eq(path)
      second.release
    end

    # Chrome holds a SingletonLock on a profile and refuses to start a second
    # process on it — concurrent sessions must never be handed the same one.
    it 'never hands the same directory to two live sessions' do
      held = 3.times.map { described_class.acquire(name) }
      expect(held.compact.map(&:path).uniq.size).to eq(3)
      held.each(&:release)
    end

    it 'returns nil rather than blocking once the pool is exhausted' do
      held = described_class::POOL_SIZE.times.map { described_class.acquire(name) }
      expect(described_class.acquire(name)).to be_nil
      held.each(&:release)
    end

    it 'frees the slot again after release' do
      held = described_class::POOL_SIZE.times.map { described_class.acquire(name) }
      held.first.release

      reacquired = described_class.acquire(name)
      expect(reacquired).to be_present
      reacquired.release
      held.drop(1).each(&:release)
    end

    it 'keeps profiles of different names apart' do
      mine  = described_class.acquire(name)
      other = described_class.acquire("#{name}_other")
      expect(other.path).not_to eq(mine.path)
      [ mine, other ].each(&:release)
      described_class.clear("#{name}_other")
    end
  end

  describe '.clear' do
    it 'removes the whole profile tree' do
      slot = described_class.acquire(name)
      File.write(File.join(slot.path, 'marker'), 'x')
      slot.release

      described_class.clear(name)
      expect(Dir.exist?(slot.path)).to be(false)
    end
  end
end
