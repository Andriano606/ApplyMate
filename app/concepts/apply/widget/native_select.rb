# frozen_string_literal: true

# A native <select>: Session#select by the option label, fallback by the option value. Read-back: the selected
# option's text. The option is always one of field.options (MatchOption); an answer that matches none (or several) is
# Apply::Widget::Mismatch before any select call: Playwright would wait ACTION_TIMEOUT for a label that is not there
# and raise a TimeoutError the engine does not treat as a widget mismatch.
class Apply::Widget::NativeSelect < Apply::Widget::Base
  def self.handles?(field)
    field.kind == 'select'
  end

  def write(value)
    option = matched_option(value) || raise(Apply::Widget::Mismatch.new(field:, wanted: value, read_back: nil))
    session.select(target, label: option['label'].to_s)
  end

  # nil without a matching option: SetFieldValue re-raises the Mismatch.
  def fallback_write(value)
    option = matched_option(value)
    return if option.nil?

    session.select(target, value: option['value'].to_s)
    true
  end

  def expected_display(value)
    option_label(value)
  end
end
