# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::Range, :browser do
  let(:ctx) { engine_context(create(:apply)) }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  it 'reaches 7 of 10 with Home and ArrowRight and reads value and aria-valuenow back' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |session, fields|
      field = fixture_field(fields, 'Years of experience')
      allow(session).to receive(:press).and_call_original

      expect(field).to have_attributes(kind: 'range', widget: 'range')
      expect(set!(field, 7).displayed).to eq('7')
      expect(session.probe(:read_value, field.target)).to include('aria_valuenow' => '7', 'min' => '0', 'max' => '10', 'step' => '1')
      expect(session).to have_received(:press).with(field.target, 'Home').once
      expect(session).to have_received(:press).with(field.target, 'ArrowRight').exactly(7).times
    end
  end
end
