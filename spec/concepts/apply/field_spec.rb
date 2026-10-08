# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Field do
  let(:browser_target) do
    ApplyMate::Client::Browser::Target.new(frame_path: [], strategies: [ { 'css' => '#name' } ], root: nil, readonly: false)
  end

  def build_field(**overrides)
    attrs = described_class.members.index_with { nil }.merge(
      id: 'name', kind: 'text', label: 'Name', required: true, target: browser_target, semantic: 'full_name',
      widget: 'text', ordinal: 0, source: 'snapshot'
    )
    described_class.new(**attrs.merge(overrides))
  end

  describe '.from_h / #to_h' do
    it 'round-trips a browser target' do
      field = build_field(default_value: 'x')

      expect(described_class.from_h(field.to_h)).to eq(field)
    end

    it 'accepts string keys, as read back from jsonb' do
      field = build_field
      stringified = JSON.parse(field.to_h.to_json)

      expect(described_class.from_h(stringified)).to eq(field)
    end

    it 'accepts a nil target' do
      field = build_field(target: nil)

      expect(described_class.from_h(field.to_h).target).to be_nil
    end

    it 'drops the default value of hidden fields only' do
      expect(build_field(kind: 'hidden', default_value: 'csrf').to_h[:default_value]).to be_nil
      expect(build_field(kind: 'text', default_value: 'kept').to_h[:default_value]).to eq('kept')
    end
  end

  describe 'predicates' do
    it 'classifies kinds' do
      expect(build_field(kind: 'file')).to be_file
      expect(build_field(kind: 'hidden')).not_to be_fillable
      expect(build_field(kind: 'text')).to be_fillable
      expect(build_field(kind: 'combobox')).to be_option_kind
      expect(build_field(kind: 'text')).not_to be_option_kind
      expect(build_field(kind: 'rich_text')).to be_textarea
    end
  end

  describe '#multi_valued?' do
    it 'is true for the multi kinds and for any kind flagged multiple' do
      expect(build_field(kind: 'multiselect')).to be_multi_valued
      expect(build_field(kind: 'checkbox_group')).to be_multi_valued
      expect(build_field(kind: 'combobox', multiple: true)).to be_multi_valued
      expect(build_field(kind: 'option_group', multiple: false)).not_to be_multi_valued
    end
  end

  describe '.signature_for' do
    it 'normalizes case and whitespace' do
      one = described_class.signature_for(label: ' Why  US? ', kind: 'textarea', option_labels: nil)
      two = described_class.signature_for(label: 'why us?', kind: 'textarea', option_labels: [])

      expect(one).to eq(two)
    end

    it 'differs by kind and option labels' do
      base = described_class.signature_for(label: 'A', kind: 'select', option_labels: %w[x y])

      expect(base).not_to eq(described_class.signature_for(label: 'A', kind: 'radio_group', option_labels: %w[x y]))
      expect(base).not_to eq(described_class.signature_for(label: 'A', kind: 'select', option_labels: %w[x z]))
    end
  end
end
