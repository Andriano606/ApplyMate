# frozen_string_literal: true

# A date control (`date` kind): a native <input type=date|month|week|datetime-local> or a masked text input whose
# placeholder is a date mask ("dd.mm.yyyy", "mm/dd/yyyy", "yyyy-mm-dd": MASK; BuildFieldInventory asks .masked? to
# give such an input the `date` kind). The answer is parsed first (ISO 8601, else Date.parse; it must hold a 4-digit
# year) - an unparseable answer is a Mismatch before anything is written. The control's type comes from a read_value
# probe: native -> `fill` in the HTML value format (NATIVE_FORMATS, ISO for type=date); otherwise clear and `type` the
# date in the placeholder's mask (tokens dd mm yyyy yy), ISO when there is no mask. Read-back: `.value`, accepted when
# it parses (in the written format, else leniently) to the same date.
class Apply::Widget::DateInput < Apply::Widget::Base
  NATIVE_FORMATS = { 'date' => '%Y-%m-%d', 'month' => '%Y-%m', 'week' => '%G-W%V', 'datetime-local' => '%Y-%m-%dT%H:%M' }.freeze
  ISO = NATIVE_FORMATS.fetch('date')
  MASK = %r{\A(?:dd|mm|yyyy|yy)(?:[./\- ](?:dd|mm|yyyy|yy)){2}\z}i
  MASK_TOKENS = { 'yyyy' => '%Y', 'yy' => '%y', 'mm' => '%m', 'dd' => '%d' }.freeze
  YEAR = /\d{4}/

  def self.handles?(field)
    field.kind == 'date'
  end

  def self.masked?(placeholder)
    MASK.match?(placeholder.to_s.strip)
  end

  def write(value)
    date = parse(value) || raise(Apply::Widget::Mismatch.new(field:, wanted: value, read_back: nil))
    type = session.probe(:read_value, target)['type'].to_s
    @format = NATIVE_FORMATS[type] || mask_format || ISO
    text = date.strftime(@format)
    return session.fill(target, text) if NATIVE_FORMATS.key?(type)

    session.fill(target, '')
    session.type(target, text)
  end

  def expected_display(value)
    parse(value)&.strftime(format) || value.to_s
  end

  def accepts?(read_back, value)
    shown = read_back.displayed.to_s.strip
    expected = expected_display(value)
    !read_back.invalid && shown.present? && (shown == expected || reparse(shown)&.strftime(format) == expected)
  end

  private

  def format
    @format || ISO
  end

  def mask_format
    placeholder = field.placeholder.to_s.strip
    return unless self.class.masked?(placeholder)

    placeholder.gsub(/yyyy|yy|mm|dd/i) { |token| MASK_TOKENS.fetch(token.downcase) }
  end

  def parse(value)
    return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

    text = value.to_s.strip
    return unless YEAR.match?(text)

    Date.iso8601(text)
  rescue ArgumentError
    lenient(text)
  end

  def lenient(text)
    Date.parse(text)
  rescue ArgumentError
    nil
  end

  def reparse(text)
    Date.strptime(text, format)
  rescue ArgumentError
    lenient(text)
  end
end
