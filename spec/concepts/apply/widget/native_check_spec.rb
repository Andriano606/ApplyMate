# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::NativeCheck, :browser do
  let(:ctx) { engine_context(create(:apply)) }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  it 'ticks a checkbox and reads checked back' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |_session, fields|
      field = fixture_field(fields, 'I agree to the privacy policy')

      expect(field).to have_attributes(kind: 'checkbox', widget: 'native_check')
      expect(set!(field, true).displayed).to eq('true')
      expect(set!(field, false).displayed).to eq('false')
    end
  end

  it 'ticks a hidden (display: none) checkbox through set_checked' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |session, fields|
      field = fields.find { |candidate| candidate.target.strategies.include?({ 'attr' => { 'id' => 'remote' } }) }
      allow(session).to receive(:set_checked).and_call_original

      expect(field).to have_attributes(kind: 'checkbox', widget: 'native_check')
      expect(set!(field, 'Yes').displayed).to eq('true')
      expect(session).to have_received(:set_checked).with(anything, true)
      expect(session.probe(:read_value, ApplyMate::Client::Browser::Target.css('#remote'))['checked']).to be(true)
    end
  end

  it 'ticks a covered opacity-0 checkbox through its label' do
    on_fixture_form(ctx, FixtureSite.alt_url('/ashby/application.html?embed=js'), form_root: '#form[role="tabpanel"]') do |_session, fields|
      field = fixture_field(fields, 'Acknowledge/Confirm')

      expect(field).to have_attributes(kind: 'checkbox', widget: 'native_check')
      expect(set!(field, true).displayed).to eq('true')
    end
  end
end
