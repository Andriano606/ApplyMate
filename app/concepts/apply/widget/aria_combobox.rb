# frozen_string_literal: true

# An ARIA combobox (react-select, Ashby's autocomplete, intl-tel-input, readonly el-select / v-select): click it
# (Engine::ClickControl: through its container when the input has no box of its own, react-select's DummyInput),
# type a prefix of the answer (unless readonly), press ArrowDown (Ashby opens ONLY on the keyboard), wait for the
# listbox options that are new since the click (Session#dom_mark / #wait_for_listbox: the field's frame and the top
# document, so portaled menus count), pick the best option with MatchOption and click it. PREFIXES: the first
# characters typed; a site whose filter returns nothing for 10 gets a second try with 4. Read-back: the chip / the
# input value.
class Apply::Widget::AriaCombobox < Apply::Widget::Base
  PREFIXES = [ 10, 4 ].freeze
  LISTBOX_TIMEOUT = 5

  def self.handles?(field)
    field.kind == 'combobox'
  end

  def settle_kind
    :click
  end

  def write(value)
    PREFIXES.each do |length|
      options = open_and_filter(value.to_s.first(length))
      label = Apply::Operation::Engine::MatchOption.call(candidates: options.map(&:label), wanted: value.to_s).model
      next if label.nil?

      return session.click(options.find { |option| option.label == label }.target)
    end
    raise Apply::Widget::Mismatch.new(field:, wanted: value, read_back: nil)
  end

  def expected_display(value)
    option_label(value)
  end

  private

  def open_and_filter(text)
    mark = session.dom_mark(target)
    Apply::Operation::Engine::ClickControl.call(ctx:, target:)
    unless target.readonly?
      session.fill(target, '')
      session.type(target, text)
    end
    session.press(target, 'ArrowDown')
    session.wait_for_listbox(since: mark, timeout: ctx.clamp(LISTBOX_TIMEOUT))
  end
end
