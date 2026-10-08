# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::OptionGroup, :browser do
  let(:ctx) { engine_context(create(:apply)) }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  it 'picks a native radio by its label' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |_session, fields|
      field = fixture_field(fields, 'Ready to relocate?')

      expect(field).to have_attributes(kind: 'radio_group', widget: 'option_group')
      expect(set!(field, 'No').displayed).to eq([ 'No' ])
    end
  end

  context 'with the Ashby application page' do
    let(:url) { FixtureSite.alt_url('/ashby/application.html?embed=js') }

    it 'clicks an opacity-0 radio through its label' do
      on_fixture_form(ctx, url, form_root: '#form[role="tabpanel"]') do |_session, fields|
        field = fixture_field(fields, 'How many years have you managed support agents?')

        expect(field.kind).to eq('radio_group')
        expect(set!(field, '3-5 years').displayed).to eq([ '3-5 years' ])
      end
    end

    it 'presses a Yes/No answer button' do
      on_fixture_form(ctx, url, form_root: '#form[role="tabpanel"]') do |_session, fields|
        field = fixture_field(fields, 'Are you open to working in shifts?')

        expect(field).to have_attributes(kind: 'option_group', widget: 'option_group')
        expect(set!(field, 'No').displayed).to eq([ 'No' ])
        expect(set!(field, 'Yes').displayed).to eq([ 'Yes' ])
      end
    end

    it 'ticks an opacity-0 checkbox of a checkbox group (Ashby MultiValueSelect)' do
      adopt_fixture_ashby!(ctx)
      on_fixture_form(ctx, url, form_root: '#form[role="tabpanel"]') do |_session, fields|
        field = fixture_field(fields, 'Privacy notice')

        expect(field).to have_attributes(kind: 'checkbox_group', widget: 'option_group')
        expect(set!(field, [ 'Acknowledge/Confirm' ]).displayed).to eq([ 'Acknowledge/Confirm' ])
      end
    end

    it 'raises Mismatch when no option matches the answer' do
      on_fixture_form(ctx, url, form_root: '#form[role="tabpanel"]') do |_session, fields|
        field = fixture_field(fields, 'How many years have you managed support agents?')

        expect { set!(field, 'Twenty decades') }.to raise_error(Apply::Widget::Mismatch)
      end
    end
  end

  it 'presses aria-pressed buttons of a role=group question' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |_session, fields|
      field = fixture_field(fields, 'Do you have a work permit?')

      expect(field).to have_attributes(kind: 'option_group', widget: 'option_group')
      expect(set!(field, 'Yes').displayed).to eq([ 'Yes' ])
    end
  end
end
