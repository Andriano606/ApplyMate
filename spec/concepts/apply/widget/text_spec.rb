# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::Text, :browser do
  let(:ctx) { engine_context(create(:apply)) }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  it 'fills a text input and reads the value back' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |_session, fields|
      field = fixture_field(fields, 'Full name')

      expect(field).to have_attributes(kind: 'text', widget: 'text', max_length: 40)
      expect(set!(field, 'Jane Doe')).to have_attributes(displayed: 'Jane Doe', invalid: false)
    end
  end

  it 'keeps the line breaks of a textarea' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |_session, fields|
      field = fixture_field(fields, 'Cover letter')

      expect(field.kind).to eq('textarea')
      expect(set!(field, "Hello,\nI am Jane.").displayed).to eq("Hello,\nI am Jane.")
    end
  end

  it 'types key by key in the submit scope' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |session, fields|
      ctx.scratch.scope = :submit
      allow(session).to receive(:type).and_call_original

      email = unique_email
      expect(set!(fixture_field(fields, 'Email'), email).displayed).to eq(email)
      expect(session).to have_received(:type).with(anything, email)
    end
  end

  it 'clears and types when the filled value does not stick (fallback)' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |session, fields|
      # A React-controlled input that "eats" the pasted value: the first fill lands a different text.
      allow(session).to receive(:fill).and_wrap_original do |original, target, text|
        original.call(target, text == 'Jane Doe' ? 'Jane' : text)
      end
      allow(session).to receive(:type).and_call_original

      expect(set!(fixture_field(fields, 'Full name'), 'Jane Doe').displayed).to eq('Jane Doe')
      expect(session).to have_received(:type).with(anything, 'Jane Doe')
      expect(ctx.scratch.trace.pluck('event')).to include('widget_fallback')
    end
  end

  it 'raises Mismatch when the value cannot stick (maxlength)' do
    on_fixture_form(ctx, FixtureSite.url('/form.html'), form_root: 'form#apply') do |_session, fields|
      field = fixture_field(fields, 'Full name')
      long = 'J' * 45

      expect { set!(field, long) }.to raise_error(Apply::Widget::Mismatch) { |error|
        expect(error.field).to eq(field)
        expect(error.read_back.displayed).to eq('J' * 40)
        expect(error.message).not_to include(long)
      }
    end
  end
end
