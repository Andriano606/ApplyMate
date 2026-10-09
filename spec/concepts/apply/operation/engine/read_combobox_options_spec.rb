# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Operation::Engine::ReadComboboxOptions do
  subject(:options) { described_class.call(ctx:, target:).model }

  let(:apply) { create(:apply) }
  let(:ctx) { engine_context(apply) }
  let(:read_values) { {} }
  let(:labels) { [] }
  let(:session) do
    listbox = labels.map do |label|
      ApplyMate::Client::Browser::Operation::WaitForListbox::Option.new(label:, target: ApplyMate::Client::Browser::Target.css('[role=option]'))
    end
    FakeSession.new(html: '', final_url: 'https://job-boards.example/acme/jobs/1', read_values:, listbox_options: listbox)
  end

  before { ctx.open_scope!(:survey, session, 10.minutes.from_now) }

  def escapes
    session.calls_of(:press).count { |(_target, key)| key == 'Escape' }
  end

  # Greenhouse's phone-country react-select (<div role="listbox" id="react-select-country-listbox">): 244 options,
  # 'United States +1' .. 'Zimbabwe +263', 'Ukraine +380' among the last ones.
  context 'with a list longer than MAX_OPTIONS (a country list)' do
    let(:target) { ApplyMate::Client::Browser::Target.css('#country') }
    let(:labels) { [ 'United States +1', *(1..241).map { |n| "Country #{n} +#{n}" }, 'Ukraine +380', 'Zimbabwe +263' ] }

    it 'keeps the field dynamic, so an answer past the cut is not refused, and closes the list' do
      expect(options).to be_nil
      expect(escapes).to eq(1)

      field = Apply::Field.new(**Apply::Field.members.index_with(nil), kind: 'combobox', label: 'Country', options: options || 'dynamic')
      coerced = Apply::Operation::Answer::CoerceValue.call(field:, value: 'Ukraine')
      expect([ coerced.model, coerced[:error] ]).to eq([ 'Ukraine', nil ])
    end
  end

  context 'with a short list' do
    let(:target) { ApplyMate::Client::Browser::Target.css('#currency') }
    let(:labels) { %w[USD EUR USD] }

    it 'returns every option (duplicates left out) and closes the list' do
      expect(options).to eq([ { 'label' => 'USD', 'value' => 'USD' }, { 'label' => 'EUR', 'value' => 'EUR' } ])
      expect(escapes).to eq(1)
    end
  end

  # Greenhouse's "Location (City)" (#candidate-location, an async geocoder react-select): ArrowDown opens an EMPTY
  # <div role="listbox" id="react-select-candidate-location-listbox"> and leaves aria-expanded="true".
  context 'with a search-driven combobox that opens an empty menu' do
    let(:target) { ApplyMate::Client::Browser::Target.css('#candidate-location') }
    let(:read_values) { { '#candidate-location' => { 'expanded' => true } } }

    it 'closes the menu it left open and keeps the field dynamic' do
      expect(options).to be_nil
      expect(escapes).to eq(1)
    end
  end

  context 'with a control that opened nothing' do
    let(:target) { ApplyMate::Client::Browser::Target.css('#plain') }
    let(:read_values) { { '#plain' => { 'expanded' => false } } }

    it 'presses no Escape (a form inside a dialog must not be closed by it)' do
      expect(options).to be_nil
      expect(escapes).to eq(0)
    end
  end
end
