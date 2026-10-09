# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Answer::Digest do
  def digest(answers)
    described_class.call(answers:).model
  end

  let(:answers) do
    { 'b' => answer_entry('x', source: 'ai', confidence: 0.4), 'a' => answer_entry([ 'p', 'q' ], source: 'fact') }
  end

  it 'is a SHA256 hex digest' do
    expect(digest(answers)).to match(/\A\h{64}\z/)
  end

  it 'ignores key order and confidence' do
    shuffled = { 'a' => answer_entry([ 'p', 'q' ], source: 'fact', confidence: 1.0), 'b' => answer_entry('x', source: 'ai', confidence: 0.9) }

    expect(digest(shuffled)).to eq(digest(answers))
  end

  it 'changes with a value or a source' do
    expect(digest(answers.merge('b' => answer_entry('y', source: 'ai')))).not_to eq(digest(answers))
    expect(digest(answers.merge('b' => answer_entry('x', source: 'user')))).not_to eq(digest(answers))
  end

  it 'sorts nested hashes and survives symbol keys and a FileRef' do
    left = { 'f' => { 'value' => { 'file' => 'cv', 'z' => 1 }, 'source' => 'fact' } }
    right = { f: { value: { 'z' => 1, 'file' => 'cv' }, source: 'fact' } }

    expect(digest(left)).to eq(digest(right))
    expect(digest({ 'f' => answer_entry(Apply::Operation::Answer::FileRef.cv, source: 'fact') }))
      .to eq(digest({ 'f' => answer_entry({ 'file' => 'cv' }, source: 'fact') }))
  end

  it 'digests no answers' do
    expect(digest(nil)).to eq(digest({}))
  end
end
