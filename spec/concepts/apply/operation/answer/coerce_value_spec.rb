# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Answer::CoerceValue do
  def coerce(value, **field)
    described_class.call(field: answer_field(**field), value:)
  end

  describe 'salary in a text input (PeopleForce answered 422 "це не число" to "500$ (gross)")' do
    {
      '500$ (gross)' => '500', '1 500 USD' => '1500', '2,500' => '2500', '3000' => '3000', '2k' => '2000',
      '2.5k' => '2500', 'від 1200 до 1500 $' => '1200', '1500.50' => '1500.5'
    }.each do |given, expected|
      it "types #{given.inspect} as #{expected.inspect}" do
        outcome = coerce(given, kind: 'text', semantic: 'salary')

        expect(outcome.model).to eq(expected)
        expect(outcome[:error]).to be_nil
      end
    end

    it 'rejects a salary answer without an amount' do
      expect(coerce('договірна', kind: 'text', semantic: 'salary')[:error]).to eq('is not a number')
    end

    it 'leaves other text fields alone' do
      expect(coerce('500$ (gross)', kind: 'text', semantic: 'other').model).to eq('500$ (gross)')
    end
  end

  it 'replaces an option answer by the matched option label' do
    outcome = coerce('yes', kind: 'radio_group', options: AnswerHelpers::YES_NO)

    expect(outcome.model).to eq('Yes')
    expect(outcome[:error]).to be_nil
  end

  it 'rejects an option that does not exist' do
    outcome = coerce('Maybe', kind: 'select', options: AnswerHelpers::YES_NO)

    expect(outcome[:error]).to include('not one of the options')
  end

  it 'matches every item of a multiple choice' do
    options = [ { 'label' => 'Ruby' }, { 'label' => 'Go' } ]

    expect(coerce(%w[ruby go], kind: 'multiselect', options:).model).to eq(%w[Ruby Go])
    expect(coerce(%w[ruby c], kind: 'multiselect', options:)[:error]).to be_present
  end

  it 'keeps every item for a single-choice kind flagged multiple (schema MultiValueSelect)' do
    options = [ { 'label' => 'Ruby' }, { 'label' => 'Rails' } ]

    expect(coerce(%w[ruby rails], kind: 'combobox', multiple: true, options:).model).to eq(%w[Ruby Rails])
    expect(coerce(%w[ruby rails], kind: 'combobox', options:).model).to eq('Ruby')
  end

  it 'takes text as given when the options are dynamic' do
    expect(coerce('Kyiv, Ukraine', kind: 'combobox', options: 'dynamic').model).to eq('Kyiv, Ukraine')
  end

  it 'coerces checkboxes and numbers' do
    expect(coerce('так', kind: 'checkbox').model).to be(true)
    expect(coerce(false, kind: 'checkbox').model).to be(false)
    expect(coerce('maybe', kind: 'checkbox')[:error]).to be_present
    expect(coerce('5000', kind: 'number').model).to eq(5000)
    expect(coerce('4,5', kind: 'number').model).to eq(4.5)
    expect(coerce('lots', kind: 'number')[:error]).to be_present
  end

  it 'types only the national part of an international phone after a fixed dial-code prefix' do
    expect(coerce('+380 67 123 45 67', kind: 'tel', prefix: '+380').model).to eq('671234567')
    expect(coerce('00380671234567', kind: 'tel', prefix: '+380').model).to eq('671234567')
    expect(coerce('+38 (067) 123-45-67', kind: 'tel', prefix: '+380').model).to eq('671234567')
    expect(coerce('+48 600 100 200', kind: 'tel', prefix: '+380').model).to eq('+48 600 100 200')
    expect(coerce('067 123 45 67', kind: 'tel', prefix: '+380').model).to eq('067 123 45 67')
    expect(coerce('+380671234567', kind: 'tel', prefix: '$').model).to eq('+380671234567')
    expect(coerce('+380671234567', kind: 'tel').model).to eq('+380671234567')
  end

  it 'truncates text to max_length' do
    expect(coerce('abcdefgh', max_length: 5).model).to eq('abcde')
  end

  it 'rejects nested values' do
    expect(coerce({ 'a' => 1 })[:error]).to be_present
  end

  it 'treats a blank value as no answer, an error only for a required field' do
    expect(coerce('  ').model).to be_nil
    expect(coerce('  ')[:error]).to be_nil
    expect(coerce(nil, required: true)[:error]).to eq('is required')
    expect(coerce(false, kind: 'checkbox', required: true)[:error]).to eq('is required')
  end
end
