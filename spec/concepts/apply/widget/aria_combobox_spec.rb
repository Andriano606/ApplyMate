# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::AriaCombobox, :browser do
  let(:ctx) { engine_context(create(:apply)) }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  def record_listboxes(session)
    listboxes = []
    allow(session).to receive(:wait_for_listbox).and_wrap_original do |original, **args|
      original.call(**args).tap { |options| listboxes << options }
    end
    listboxes
  end

  it 'opens the Ashby autocomplete with ArrowDown, picks the option and reads the chip back' do
    on_fixture_form(ctx, FixtureSite.alt_url('/ashby/application.html?embed=js'), form_root: '#form[role="tabpanel"]') do |session, fields|
      field = fixture_field(fields, 'How did you get to know Preply?')
      allow(session).to receive(:press).and_call_original
      listboxes = record_listboxes(session)

      expect(field).to have_attributes(kind: 'combobox', widget: 'aria_combobox')
      expect(set!(field, 'LinkedIn').displayed).to eq('LinkedIn')
      expect(session).to have_received(:press).with(field.target, 'ArrowDown')
      expect(listboxes.first.map(&:label)).to include('LinkedIn')
    end
  end

  it 'lists all 15 options when nothing is typed' do
    on_fixture_form(ctx, FixtureSite.alt_url('/ashby/application.html?embed=js'), form_root: '#form[role="tabpanel"]') do |session, fields|
      field = fixture_field(fields, 'How did you get to know Preply?')
      session.click(field.target)
      mark = session.dom_mark(field.target)
      session.press(field.target, 'ArrowDown')

      expect(session.wait_for_listbox(since: mark, timeout: 5).size).to eq(15)
    end
  end

  it 'picks from a menu portaled to <body> (react-select) and reads the single-value chip' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |_session, fields|
      field = fixture_field(fields, 'Country')

      expect(field).to have_attributes(kind: 'combobox', widget: 'aria_combobox')
      expect(set!(field, 'Poland').displayed).to eq('Poland')
    end
  end

  it 'never types into a readonly el-select and picks from its pre-rendered dropdown' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |session, fields|
      field = fixture_field(fields, 'City')
      allow(session).to receive(:type).and_call_original

      expect(field).to have_attributes(kind: 'combobox', widget: 'aria_combobox')
      expect(field.target).to be_readonly
      expect(set!(field, 'Lviv').displayed).to eq('Lviv')
      expect(session).not_to have_received(:type)
    end
  end

  it 'raises Mismatch when no option matches after both prefixes' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |_session, fields|
      stub_const('Apply::Widget::AriaCombobox::LISTBOX_TIMEOUT', 1)

      expect { set!(fixture_field(fields, 'Country'), 'Atlantis') }.to raise_error(Apply::Widget::Mismatch)
    end
  end
end
