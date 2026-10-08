# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::NativeSelect, :browser do
  let(:ctx) { engine_context(create(:apply)) }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  it 'selects by option label and reads the selected text back' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |_session, fields|
      field = fixture_field(fields, 'Experience')

      expect(field).to have_attributes(kind: 'select', widget: 'native_select')
      expect(field.options).to eq([ { 'label' => '1-2 years', 'value' => 'junior' }, { 'label' => '5+ years', 'value' => 'senior' } ])
      expect(set!(field, '5+ years').displayed).to eq('5+ years')
    end
  end

  it 'accepts an answer given as the option value' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |_session, fields|
      expect(set!(fixture_field(fields, 'Experience'), 'junior').displayed).to eq('1-2 years')
    end
  end

  it 'is a Mismatch, before any select call, when the answer matches no option' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |session, fields|
      allow(session).to receive(:select).and_call_original

      expect { set!(fixture_field(fields, 'Experience'), 'Twenty years of COBOL') }.to raise_error(Apply::Widget::Mismatch)
      expect(session).not_to have_received(:select)
    end
  end

  it 'falls back to selecting by value when the label select does not stick' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |session, fields|
      allow(session).to receive(:select).and_wrap_original do |original, target, value: nil, label: nil|
        label ? nil : original.call(target, value:)
      end

      expect(set!(fixture_field(fields, 'Experience'), '5+ years').displayed).to eq('5+ years')
      expect(session).to have_received(:select).with(anything, value: 'senior')
    end
  end
end
