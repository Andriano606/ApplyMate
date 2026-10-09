# frozen_string_literal: true

require 'rails_helper'

# The REAL snapshot.js + listbox.js + read_value.js, BuildFieldInventory and the widget drivers on
# generic/custom_widgets.html: custom selects with no native <select> (PeopleForce's Alpine select, a Headless UI
# button trigger), an ARIA-less typeahead (Lever's location input), a typeahead-looking input whose list never fills,
# and the chooser link / button of a file input (Lever's anchor around it, Ashby's "Upload file" beside it).
RSpec.describe Apply::Operation::Engine::BuildFieldInventory, :browser do
  let(:ctx) { engine_context(create(:apply)) }
  let(:url) { FixtureSite.url('/generic/custom_widgets.html') }

  before { ctx.adopt_match!(Apply::Operation::Engine::Detect::Match.generic) }

  def displayed(session, css)
    session.probe(:read_value, ApplyMate::Client::Browser::Target.css(css))['displayed']
  end

  def write(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:)
  end

  it 'types custom selects as comboboxes with the options read by opening them, typeaheads as autocompletes' do
    on_fixture_form(ctx, url, form_root: '#apply') do |session, fields|
      currency = fixture_field(fields, 'Валюта')
      country = fixture_field(fields, 'Country')

      expect(currency).to have_attributes(kind: 'combobox', widget: 'aria_combobox', required: true)
      expect(currency.options.pluck('label')).to eq([ 'AED - UAE Dirham', 'EUR - Euro', 'USD - United States Dollar' ])
      expect(country).to have_attributes(kind: 'combobox', widget: 'aria_combobox')
      expect(country.options.pluck('label')).to eq(%w[Ukraine Poland])
      expect(fixture_field(fields, 'Current location')).to have_attributes(kind: 'autocomplete', widget: 'typeahead', options: 'dynamic')
      expect(fixture_field(fields, 'City')).to have_attributes(kind: 'autocomplete', widget: 'typeahead')
      # Probing closed both lists again and picked nothing.
      expect(session.dom_mark(currency.target)[:option_count]).to eq(0)
      expect([ displayed(session, '#currency'), displayed(session, '#country-trigger') ]).to eq([ 'USD - United States Dollar', 'Select...' ])
    end
  end

  it 'fills the custom selects through AriaCombobox and reads the pick back' do
    on_fixture_form(ctx, url, form_root: '#apply') do |session, fields|
      expect(write(fixture_field(fields, 'Валюта'), 'EUR - Euro').model.displayed).to eq('EUR - Euro')
      expect(write(fixture_field(fields, 'Country'), 'Poland').model.displayed).to eq('Poland')

      expect([ displayed(session, '#currency'), displayed(session, '#country-trigger') ]).to eq([ 'EUR - Euro', 'Poland' ])
    end
  end

  it 'picks a typeahead suggestion, and keeps the typed text when no suggestion ever appears' do
    on_fixture_form(ctx, url, form_root: '#apply') do |session, fields|
      location = write(fixture_field(fields, 'Current location'), 'Lviv, Lviv Oblast, Ukraine')
      city = write(fixture_field(fields, 'City'), 'Odesa')

      expect(location.model.displayed).to eq('Lviv, Lviv Oblast, Ukraine')
      expect(location[:approximate]).to be_nil
      expect(city.model.displayed).to eq('Odesa')
      expect([ displayed(session, '#location-input'), displayed(session, '#city') ]).to eq([ 'Lviv, Lviv Oblast, Ukraine', 'Odesa' ])
    end
  end

  it "treats a file input's chooser link / button as part of the file field" do
    on_fixture_form(ctx, url, form_root: '#apply') do |session, fields|
      snapshot = session.snapshot_all
      triggers = %w[cv-button cover-chooser].map do |id|
        snapshot.elements.find { |element| element.dig('attrs', 'id') == id }
      end
      prompt = Apply::Ai::Prompt::Navigate.new(ctx:, snapshot:, previous: nil, turn: 1, max_turns: 12, ai_calls: 0, max_ai_calls: 30,
                                               recipe: [], forbidden: [], heal_hint: nil, last_action: nil).call

      expect(triggers).to all(include('file_trigger' => true, 'submit_like' => false, 'required' => false))
      expect(fields.select { |field| field.kind == 'file' }.map(&:label)).to eq([ 'Resume', 'Cover letter' ])
      expect(prompt).not_to include('Upload file', 'ATTACH COVER LETTER')
      expect(Apply::Operation::Engine::ExecuteAction.call(ctx:, action: { 'type' => 'click', 'ref' => triggers.first['ref'] },
                                                          snapshot:)[:rejected]).to eq('file_trigger')
    end
  end
end
