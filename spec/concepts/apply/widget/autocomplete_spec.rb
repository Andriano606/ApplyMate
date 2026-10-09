# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::Autocomplete, :browser do
  let(:ctx) { engine_context(create(:apply)) }

  def set_value(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:)
  end

  it 'types a prefix (no ArrowDown), picks the matching suggestion and reads the input back' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |session, fields|
      field = fixture_field(fields, 'School')
      allow(session).to receive(:press).and_call_original

      expect(field).to have_attributes(kind: 'autocomplete', widget: 'autocomplete', options: 'dynamic')
      result = set_value(field, 'Kyiv-Mohyla Academy')
      expect(result.model.displayed).to eq('Kyiv-Mohyla Academy')
      expect(result[:approximate]).to be_nil
      expect(session).not_to have_received(:press)
    end
  end

  it 'picks the first suggestion as an approximate pick when none matches the answer' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |_session, fields|
      stub_const('Apply::Widget::Autocomplete::MAX_WAIT', 1)
      field = fixture_field(fields, 'School')

      result = set_value(field, 'Lviv State College')
      expect(result.model.displayed).to eq('Lviv Polytechnic National University')
      expect(result[:approximate]).to eq('Lviv Polytechnic National University')
    end
  end

  it 'raises Mismatch when no prefix brings up any suggestion' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |_session, fields|
      stub_const('Apply::Widget::Autocomplete::MAX_WAIT', 1)

      expect { set_value(fixture_field(fields, 'School'), 'Atlantis University') }.to raise_error(Apply::Widget::Mismatch)
    end
  end
end
