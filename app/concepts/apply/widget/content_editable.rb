# frozen_string_literal: true

# A contenteditable editor (BuildFieldInventory's `rich_text`: a cover-letter box that is a div, not a textarea):
# click, select everything (Control+a) so the old text is replaced, then `type` in the submit scope (Text's rule:
# jitter, values up to TYPE_LIMIT) or `fill` (Playwright fills contenteditable hosts too). Fallback: `fill`.
# Read-back: the host's innerText (`value` of read_value.js, not the 500-character `displayed`), whitespace squished,
# must equal the answer exactly (Text#accepts?).
class Apply::Widget::ContentEditable < Apply::Widget::Text
  SELECT_ALL = 'Control+a'

  def self.handles?(field)
    field.kind == 'rich_text'
  end

  def write(value)
    text = value.to_s
    session.click(target)
    session.press(target, SELECT_ALL)
    typed?(text) ? session.type(target, text) : session.fill(target, text)
  end

  def fallback_write(value)
    session.fill(target, value.to_s)
    true
  end

  def read
    raw = session.probe(:read_value, target)
    ReadBack.new(displayed: raw['value'], invalid: raw['invalid'] == true, error_text: raw['error_text'])
  end
end
