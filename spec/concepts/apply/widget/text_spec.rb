# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::Text do
  # The read-back comparator (#accepts?) without a browser: the driver only needs the field for it.
  describe '#accepts?' do
    let(:national) { unique_phone.delete_prefix('+380') } # 9 random digits
    let(:masked) { [ national[0, 2], national[2, 3], national[5, 2], national[7, 2] ].join(' ') }
    let(:tel) { answer_field(kind: 'tel', semantic: 'phone', prefix: '+380') }

    def accepts?(field, displayed, value, invalid: false)
      read_back = Apply::Widget::Base::ReadBack.new(displayed:, invalid:, error_text: nil)
      described_class.new(ctx: nil, field:).accepts?(read_back, value)
    end

    def other_digits(digits)
      digits.succ.last(digits.length)
    end

    it 'accepts a masked phone whatever the mask adds around the same digits' do
      parenthesised = "(#{national[0, 2]}) #{national[2, 3]}-#{national[5, 2]}-#{national[7, 2]}"
      dotted = "#{national[0, 2]}.#{national[2, 3]}.#{national[5, 2]}.#{national[7, 2]}"

      expect([ masked, parenthesised, dotted, "+380 #{masked}", "380#{national}", "#{national[0, 2]}\u00A0#{national[2..]}" ]
        .map { |shown| accepts?(tel, shown, national) }).to all(be(true))
    end

    it 'never accepts other digits, a cut value or extra text' do
      expect(accepts?(tel, masked.sub(/\d\z/) { |digit| other_digits(digit) }, national)).to be(false)
      expect(accepts?(tel, masked[0..-2], national)).to be(false)
      expect(accepts?(tel, "#{masked}0", national)).to be(false)
      expect(accepts?(tel, "#{masked} ext", national)).to be(false)
      expect(accepts?(tel, '', national)).to be(false)
    end

    it 'strips only the prefix code the field shows, not any leading digits' do
      expect(accepts?(tel, "+48 #{masked}", national)).to be(false)
      expect(accepts?(tel.with(prefix: nil), "+380 #{masked}", national)).to be(false)
      expect(accepts?(tel.with(prefix: nil), "+380 #{masked}", "+380#{national}")).to be(true)
    end

    it 'rejects an invalid control even when the digits match' do
      expect(accepts?(tel, masked, national, invalid: true)).to be(false)
    end

    it 'compares a number-like answer of a text field by its digits, keeping decimals exact' do
      text = answer_field(kind: 'text')

      expect(accepts?(text, '3 000', '3000')).to be(true)
      expect(accepts?(text, '3 001', '3000')).to be(false)
      expect(accepts?(text, '15', '1.5')).to be(false)
      expect(accepts?(answer_field(kind: 'number'), '1.5', 1.5)).to be(true)
    end

    it 'compares any other text exactly after collapsing whitespace' do
      text = answer_field(kind: 'text')

      expect(accepts?(text, "  Jane \n Doe ", 'Jane Doe')).to be(true)
      expect(accepts?(text, 'Jane', 'Jane Doe')).to be(false)
      expect(accepts?(text, 'jane doe', 'Jane Doe')).to be(false)
      expect(accepts?(text, 'Jane-Doe', 'Jane Doe')).to be(false)
    end
  end

  it 'leaves dates to Widget::DateInput' do
    expect(described_class::KINDS).not_to include('date')
    expect(described_class.handles?(answer_field(kind: 'date'))).to be(false)
  end

  context 'with the real browser', :browser do
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

    it 'accepts the digits a phone mask reformats behind a fixed +380 span (fill)' do
      on_fixture_form(ctx, FixtureSite.url('/generic/masked_phone.html'), form_root: 'form#apply') do |_session, fields|
        field = fixture_field(fields, 'Телефон')
        national = unique_phone.delete_prefix('+380')

        expect(set!(field, national).displayed)
          .to eq([ national[0, 2], national[2, 3], national[5, 2], national[7, 2] ].join(' '))
        expect(ctx.scratch.trace.pluck('event')).not_to include('widget_fallback')
      end
    end
  end
end
