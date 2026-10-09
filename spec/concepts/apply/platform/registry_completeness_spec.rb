# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Platform::Registry do
  concepts = Rails.root.join('app/concepts')
  platform_dir = concepts.join('apply/platform')
  Dir[platform_dir.join('**/*.rb')].each do |file|
    Pathname(file).relative_path_from(concepts).to_s.delete_suffix('.rb').camelize.constantize
  end

  adapters = Apply::Platform::Base.descendants.select do |klass|
    klass.name && Object.const_source_location(klass.name)&.first.to_s.start_with?(platform_dir.to_s)
  end

  it 'finds the adapters (the check below is not vacuous)' do
    expect(adapters).to include(Apply::Platform::Ashby, Apply::Platform::Generic)
  end

  it 'lists every adapter in app/concepts/apply/platform except Generic exactly once' do
    listed = described_class::PLATFORMS + described_class::BOARD_PLATFORMS

    expect(listed.tally.values).to all(eq(1))
    expect(listed.sort).to eq((adapters - [ Apply::Platform::Generic ]).map(&:name).sort)
  end

  it 'gives board platforms no signals (they are pinned, never detected)' do
    expect(described_class.board_platforms.flat_map(&:signals)).to be_empty
  end

  it 'gives Generic no signals' do
    expect(Apply::Platform::Generic.signals).to be_empty
  end

  it 'gives every detected platform a unique key and at least one signal' do
    expect(described_class.platforms.map(&:key)).to eq(described_class.platforms.map(&:key).uniq)
    expect(described_class.platforms.map(&:signals)).to all(be_present)
  end

  describe '.fingerprint' do
    let(:changed) do
      Class.new(Apply::Platform::Base) do
        def self.key
          'ashby'
        end
      end
    end

    it 'changes when a signal changes' do
      Apply::Platform::Ashby.signals.each do |signal|
        changed.signal(signal.kind, signal.pattern, weight: signal.weight, captures: signal.captures)
      end
      same = described_class.fingerprint_of([ changed ])
      changed.signals.last.then { |last| changed.signals[-1] = last.with(weight: last.weight - 0.1) }

      expect(same).to eq(described_class.fingerprint)
      expect(described_class.fingerprint_of([ changed ])).not_to eq(described_class.fingerprint)
    end

    it 'changes when a platform is added' do
      expect(described_class.fingerprint_of(described_class.platforms + [ changed ])).not_to eq(described_class.fingerprint)
    end
  end

  describe '.find!' do
    it 'finds detected platforms and Generic by key' do
      expect(described_class.find!('ashby')).to eq(Apply::Platform::Ashby)
      expect(described_class.find!('generic')).to eq(Apply::Platform::Generic)
    end

    it 'raises for an unknown key' do
      expect { described_class.find!('workday') }.to raise_error(ArgumentError, /workday/)
    end
  end

  it 'knows the hosts named by :host signals' do
    expect(described_class.known_host?('jobs.ashbyhq.com')).to be(true)
    expect(described_class.known_host?('preply.com')).to be(false)
  end

  it 'collects the DOM markers detect.js counts' do
    expect(described_class.dom_markers).to eq([ '.ashby-application-form-field-entry' ])
  end
end
