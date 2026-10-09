# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Apply::Widget::Registry do
  def field(kind, widget: nil)
    answer_field(kind:, widget:)
  end

  it 'lists every driver under apply/widget exactly once, in precedence order' do
    on_disk = Rails.root.glob('app/concepts/apply/widget/*.rb').map { |path| path.basename('.rb').to_s } - %w[base registry mismatch]

    expect(described_class.drivers.map(&:key)).to match_array(on_disk)
    expect(described_class.drivers.map(&:key)).to eq(
      %w[dropzone file_input aria_combobox typeahead autocomplete native_select option_group native_check date_input range content_editable text]
    )
  end

  it 'memoizes the constantized drivers and the key index' do
    expect(described_class.drivers).to be(described_class.drivers)
    expect(described_class.by_key).to be(described_class.by_key)
    expect(described_class.by_key.keys).to eq(described_class.drivers.map(&:key))
  end

  {
    'text' => Apply::Widget::Text, 'email' => Apply::Widget::Text, 'tel' => Apply::Widget::Text, 'url' => Apply::Widget::Text,
    'number' => Apply::Widget::Text, 'textarea' => Apply::Widget::Text, 'date' => Apply::Widget::DateInput,
    'select' => Apply::Widget::NativeSelect, 'checkbox' => Apply::Widget::NativeCheck,
    'radio_group' => Apply::Widget::OptionGroup, 'option_group' => Apply::Widget::OptionGroup,
    'checkbox_group' => Apply::Widget::OptionGroup, 'combobox' => Apply::Widget::AriaCombobox, 'file' => Apply::Widget::FileInput,
    'autocomplete' => Apply::Widget::Autocomplete, 'rich_text' => Apply::Widget::ContentEditable, 'range' => Apply::Widget::Range
  }.each do |kind, driver|
    it "picks #{driver.name.demodulize} for a #{kind} field" do
      expect(described_class.for(field(kind))).to eq(driver)
    end
  end

  it 'prefers the widget key the inventory stored' do
    expect(described_class.for(field('text', widget: 'aria_combobox'))).to eq(Apply::Widget::AriaCombobox)
  end

  it 'keeps a stored dropzone on its driver; a file field without that key is a FileInput' do
    expect(described_class.for(field('file', widget: 'dropzone'))).to eq(Apply::Widget::Dropzone)
    expect(Apply::Widget::Dropzone.handles?(field('file'))).to be(false)
  end

  it 'falls back to handles? when the stored key is unknown' do
    expect(described_class.for(field('select', widget: 'retired_driver'))).to eq(Apply::Widget::NativeSelect)
  end

  it 'has no driver for kinds the engine does not fill (find is nil, for halts no_widget_driver)' do
    %w[multiselect hidden].each do |kind|
      expect(described_class.find(field(kind))).to be_nil
      expect { described_class.for(field(kind)) }.to raise_error(Apply::Operation::Engine::Halt) { |halt|
        expect(halt).to have_attributes(code: :no_widget_driver, detail: kind)
      }
    end
  end
end
