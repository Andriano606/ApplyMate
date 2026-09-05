# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::FieldFingerprint do
  let(:base_field) do
    { 'tag' => 'input', 'type' => 'email', 'autocomplete' => 'email',
      'accessible_name' => 'Ваш email *', 'name' => 'user_email' }
  end

  it 'is stable across Vue/React random id suffixes' do
    a = described_class.call(base_field.merge('name' => 'input-33'))
    b = described_class.call(base_field.merge('name' => 'input-97'))
    expect(a).to eq(b)
  end

  it 'ignores position and handle — reordering must not invalidate recipes' do
    a = described_class.call(base_field.merge('position' => 1, 'handle' => 1))
    b = described_class.call(base_field.merge('position' => 7, 'handle' => 7))
    expect(a).to eq(described_class.call(base_field))
    expect(a).to eq(b)
  end

  it 'normalizes case and whitespace in names and labels' do
    a = described_class.call(base_field.merge('accessible_name' => '  Ваш   EMAIL * '))
    expect(a).to eq(described_class.call(base_field))
  end

  it 'changes when the accessible name differs' do
    expect(described_class.call(base_field.merge('accessible_name' => 'Телефон')))
      .not_to eq(described_class.call(base_field))
  end

  it 'changes when the input type differs' do
    expect(described_class.call(base_field.merge('type' => 'text')))
      .not_to eq(described_class.call(base_field))
  end

  it 'falls back to label when accessible_name is absent' do
    a = described_class.call(base_field.except('accessible_name').merge('label' => 'Ваш email *'))
    expect(a).to eq(described_class.call(base_field))
  end

  it 'tolerates missing keys' do
    expect { described_class.call({}) }.not_to raise_error
    expect(described_class.call({})).to match(/\A[0-9a-f]{40}\z/)
  end

  it 'accepts symbol keys' do
    expect(described_class.call(base_field.symbolize_keys)).to eq(described_class.call(base_field))
  end
end
