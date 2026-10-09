# frozen_string_literal: true

require 'rails_helper'

# The REAL snapshot.js + listbox.js + read_value.js, BuildFieldInventory, ReadComboboxOptions and AriaCombobox on
# generic/react_select.html (Greenhouse's react-select inputs): a 244-entry country list and an async geocoder whose
# menu opens empty.
RSpec.describe Apply::Operation::Engine::ReadComboboxOptions, :browser do
  let(:ctx) { engine_context(create(:apply)) }
  let(:url) { FixtureSite.url('/generic/react_select.html') }

  before { ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic) }

  def expanded(session, css)
    session.probe(:read_value, ApplyMate::Client::Browser::Target.css(css))['expanded']
  end

  it 'keeps a list longer than MAX_OPTIONS dynamic, so an answer past the cut is accepted and filled' do
    on_fixture_form(ctx, url, form_root: '#application-form') do |session, fields|
      country = fixture_field(fields, 'Country')
      expect(country).to have_attributes(kind: 'combobox', widget: 'aria_combobox', options: 'dynamic')

      coerced = Apply::Operation::Answer::CoerceValue.call(field: country, value: 'Ukraine')
      expect([ coerced.model, coerced[:error] ]).to eq([ 'Ukraine', nil ])
      write = Apply::Operation::Engine::SetFieldValue.call(ctx:, field: country, value: coerced.model)
      expect(write.model.displayed).to eq('Ukraine +380')
      expect(expanded(session, '#country')).to be(false)
    end
  end

  it 'closes a search-driven menu that opened empty' do
    on_fixture_form(ctx, url, form_root: '#application-form') do |session, fields|
      expect(fixture_field(fields, 'Location (City)')).to have_attributes(kind: 'combobox', options: 'dynamic')
      expect(expanded(session, '#candidate-location')).to be(false)
      expect(session.dom_mark(fixture_field(fields, 'Location (City)').target)[:containers].values.flat_map(&:keys)).to be_empty
    end
  end

  it "opens a react-select DummyInput (no box of its own) through its control, reads the options and fills one" do
    on_fixture_form(ctx, url, form_root: '#application-form') do |session, fields|
      english = fixture_field(fields, 'Level of English')
      expect(english).to have_attributes(kind: 'combobox', widget: 'aria_combobox')
      expect(english.options.pluck('label')).to eq(%w[Beginner Intermediate Upper-Intermediate Advanced])
      expect(expanded(session, '#react-select-english-input')).to be(false)

      started = Time.current
      write = Apply::Operation::Engine::SetFieldValue.call(ctx:, field: english, value: 'Advanced')
      expect(write.model.displayed).to eq('Advanced')
      expect(Time.current - started).to be < 5
    end
  end
end
