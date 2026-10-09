# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::ContentEditable, :browser do
  let(:ctx) { engine_context(create(:apply)) }
  let(:letter) { 'I would love to build the apply engine with you.' }

  def set!(field, value)
    Apply::Operation::Engine::SetFieldValue.call(ctx:, field:, value:).model
  end

  it 'replaces the existing draft (Control+a, fill) and reads the text back' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body') do |session, fields|
      field = fixture_field(fields, 'Cover letter')
      allow(session).to receive(:press).and_call_original

      expect(field).to have_attributes(kind: 'rich_text', widget: 'content_editable')
      expect(set!(field, letter).displayed).to eq(letter)
      expect(session).to have_received(:press).with(field.target, 'Control+a')
    end
  end

  it 'types over the selected draft in the submit scope' do
    on_fixture_form(ctx, FixtureSite.url('/widgets.html'), form_root: 'body', scope: :submit) do |session, fields|
      field = fixture_field(fields, 'Cover letter')
      allow(session).to receive(:type).and_call_original
      allow(session).to receive(:fill).and_call_original

      expect(set!(field, letter).displayed).to eq(letter)
      expect(session).to have_received(:type).with(field.target, letter)
      expect(session).not_to have_received(:fill)
    end
  end
end
