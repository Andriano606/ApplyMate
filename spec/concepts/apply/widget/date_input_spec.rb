# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::DateInput, :browser do
  let(:ctx) { engine_context(create(:apply)) }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  it 'fills an ISO date into a type=date input, whatever format the answer is in' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |session, fields|
      field = fixture_field(fields, 'Start date')
      allow(session).to receive(:fill).and_call_original

      expect(field).to have_attributes(kind: 'date', widget: 'date_input')
      expect(set!(field, '1 March 2027').displayed).to eq('2027-03-01')
      expect(session).to have_received(:fill).with(field.target, '2027-03-01')
    end
  end

  it 'types the date in the placeholder mask of a masked text input' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |session, fields|
      field = fixture_field(fields, 'Birth date')
      allow(session).to receive(:type).and_call_original

      expect(field).to have_attributes(kind: 'date', widget: 'date_input', placeholder: 'dd.mm.yyyy')
      expect(set!(field, '1990-03-15').displayed).to eq('15.03.1990')
      expect(session).to have_received(:type).with(field.target, '15.03.1990')
    end
  end

  it 'raises Mismatch before writing anything when the answer is no date' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |session, fields|
      field = fixture_field(fields, 'Start date')
      allow(session).to receive(:fill).and_call_original

      expect { set!(field, 'as soon as possible') }.to raise_error(Apply::Widget::Mismatch)
      expect(session).not_to have_received(:fill)
    end
  end
end
