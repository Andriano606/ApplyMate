# frozen_string_literal: true

# Which widget driver writes a field (design §7.2): the one whose key discovery stored in Apply::Field#widget, else the
# first in DRIVERS whose handles? is true. Precedence matters (a chooser-only dropzone before a file input, file
# inputs before anything text-like, a combobox before a native select, the specific text-ish kinds before Text;
# Typeahead is only ever picked by its stored key). Constantized once per process.
class Apply::Widget::Registry
  DRIVERS = %w[
    Apply::Widget::Dropzone Apply::Widget::FileInput Apply::Widget::AriaCombobox Apply::Widget::Typeahead
    Apply::Widget::Autocomplete Apply::Widget::NativeSelect Apply::Widget::OptionGroup Apply::Widget::NativeCheck Apply::Widget::DateInput
    Apply::Widget::Range Apply::Widget::ContentEditable Apply::Widget::Text
  ].freeze

  class << self
    def drivers
      @drivers ||= DRIVERS.map(&:constantize).freeze
    end

    def by_key
      @by_key ||= drivers.index_by(&:key).freeze
    end

    # The driver class, or nil (discovery stores no widget for a kind phase 3a cannot write).
    def find(field)
      by_key[field.widget] || drivers.find { |driver| driver.handles?(field) }
    end

    # The driver class, or Halt(:no_widget_driver, detail: kind) when no driver writes this kind.
    def for(field)
      find(field) || raise(Apply::Operation::Engine::Halt.new(:no_widget_driver, detail: field.kind))
    end
  end
end
