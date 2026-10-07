# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::Halt do
  it 'maps every code to a kind that maps to a real Apply state' do
    described_class::CODES.each do |code, kind|
      halt = described_class.new(code)

      expect(halt.kind).to eq(kind)
      expect(Apply.states).to have_key(halt.state.to_s)
    end
  end

  it 'covers every KIND_STATE kind with at least one code' do
    expect(described_class::CODES.values.uniq).to match_array(described_class::KIND_STATE.keys)
  end

  it 'routes the "apply yourself" and backfill codes' do
    expect(described_class.new(:manual_apply_required).state).to eq(:needs_human)
    expect(described_class.new(:legacy_failure).state).to eq(:failed)
  end

  it 'maps kinds to states' do
    expect(described_class.new(:worker_lost).state).to eq(:failed)
    expect(described_class.new(:no_application_path).state).to eq(:unsupported)
    expect(described_class.new(:already_claimed).state).to eq(:submit_unverified)
    expect(described_class.new(:review).state).to eq(:needs_review)
  end

  it 'accepts string codes and keeps the detail' do
    halt = described_class.new('deadline', detail: 'took too long')

    expect(halt.code).to eq(:deadline)
    expect(halt.detail).to eq('took too long')
    expect(halt.message).to eq('deadline: took too long')
  end

  it 'raises on an unknown code' do
    expect { described_class.new(:nope) }.to raise_error(ArgumentError, /Unknown halt code nope/)
  end

  describe '#releases_claim?' do
    it 'is true only for a definitive claim-releasing code' do
      expect(described_class.new(:validation_rejected, definitive: true).releases_claim?).to be(true)
      expect(described_class.new(:session_expired, definitive: true).releases_claim?).to be(true)
    end

    it 'is false without definitive proof' do
      expect(described_class.new(:validation_rejected).releases_claim?).to be(false)
    end

    it 'is false for other codes even when definitive' do
      expect(described_class.new(:unexpected_error, definitive: true).releases_claim?).to be(false)
    end
  end
end
