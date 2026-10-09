# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::MatchOption do
  def match(candidates, wanted)
    described_class.call(candidates:, wanted:).model
  end

  let(:options) do
    [ { 'label' => 'Remote', 'value' => 'r' }, { 'label' => 'Hybrid (Kyiv)', 'value' => 'h' }, { 'label' => 'On-site', 'value' => 'o' } ]
  end

  it 'matches the exact normalized label, ignoring case, punctuation and accents of spacing' do
    expect(match(options, '  remote ')).to eq(options[0])
    expect(match(options, 'ON SITE')).to eq(options[2])
  end

  it 'matches the exact value after the label' do
    expect(match(options, 'h')).to eq(options[1])
  end

  it 'matches plain string candidates and returns the candidate as given' do
    expect(match(%w[Yes No], 'no')).to eq('No')
  end

  it 'maps boolean synonyms onto yes / no options by label or value' do
    yes_no = [ { 'label' => 'Так', 'value' => 'yes' }, { 'label' => 'Ні', 'value' => 'no' } ]

    expect(match(yes_no, 'true')).to eq(yes_no[0])
    expect(match(yes_no, 'Ні')).to eq(yes_no[1])
    expect(match(yes_no, '0')).to eq(yes_no[1])
    expect(match([ { 'label' => 'Agreed', 'value' => 'true' }, { 'label' => 'Declined', 'value' => 'false' } ], 'yes'))
      .to eq({ 'label' => 'Agreed', 'value' => 'true' })
  end

  it 'matches when the candidate contains the wanted text or the other way round, on word boundaries' do
    expect(match(options, 'Hybrid')).to eq(options[1])
    expect(match(options, 'I prefer remote work')).to eq(options[0])
    expect(match([ { 'label' => 'No' } ], 'I do not know')).to be_nil
  end

  it 'is nil when containment is ambiguous' do
    both = [ { 'label' => 'Remote Europe' }, { 'label' => 'Remote USA' } ]

    expect(match(both, 'remote')).to be_nil
  end

  it 'matches on token overlap from 0.6 up' do
    levels = [ { 'label' => 'Bachelor degree in computer science' }, { 'label' => 'Master degree' } ]

    expect(match(levels, 'computer science bachelor degree')).to eq(levels[0])
    expect(match(levels, 'phd in physics')).to be_nil
  end

  it 'is nil when there is no match, no candidates or nothing wanted' do
    expect(match(options, 'Mars')).to be_nil
    expect(match([], 'x')).to be_nil
    expect(match(options, '  ')).to be_nil
  end

  describe '.same?' do
    it 'is the same rule applied to one displayed text' do
      expect(described_class.same?('Remote', 'remote')).to be(true)
      expect(described_class.same?('Yes', 'true')).to be(true)
      expect(described_class.same?('Remote', 'on-site')).to be(false)
    end
  end
end
