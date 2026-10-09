# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::RedactTree do
  let(:apply) { create(:apply) }

  def redact(value)
    described_class.call(value:, apply:).model
  end

  it 'redacts every string leaf of nested hashes and arrays and keeps the rest' do
    value = { 'a' => [ "mail #{apply.user.email}", 3, nil, true ], 'b' => { 'c' => 'ok', 'token' => 'x=1&code=secret1' } }

    expect(redact(value)).to eq(
      'a' => [ 'mail {{fact.email}}', 3, nil, true ], 'b' => { 'c' => 'ok', 'token' => 'x=1&code=[REDACTED]' }
    )
  end

  it 'passes nil through' do
    expect(redact(nil)).to be_nil
  end
end
