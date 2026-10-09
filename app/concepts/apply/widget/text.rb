# frozen_string_literal: true

# Text-like inputs and textareas (dates are Widget::DateInput's): `fill`; in the submit scope (the lease that clicks
# submit, where invisible captchas score the interaction) `type` with 40-90 ms between keys, after clearing the field.
# Fallback: clear and `type` (a React-controlled input that "ate" the filled value usually takes typed keys).
# Widget::ContentEditable inherits the typing rule and the exact read-back.
class Apply::Widget::Text < Apply::Widget::Base
  KINDS = %w[text email tel url number textarea].freeze
  # Longest answer typed key by key; a longer one is filled (pasted): at 40-90 ms per key a 1 000-character letter
  # would eat a minute of the submit scope (SCOPE_DEADLINE 8 min, SUBMIT_RESERVE 120 s).
  TYPE_LIMIT = 300

  def self.handles?(field)
    KINDS.include?(field.kind)
  end

  def write(value)
    text = value.to_s
    return session.fill(target, text) unless typed?(text)

    session.fill(target, '')
    session.type(target, text)
  end

  def fallback_write(value)
    session.fill(target, '')
    session.type(target, value.to_s)
    true
  end

  # Text must stick exactly: option-style matching would accept "Jane" for "Jane Doe" (maxlength). Only whitespace
  # is normalised (a single-line input drops line breaks, a textarea normalises \r\n).
  def accepts?(read_back, value)
    !read_back.invalid && read_back.displayed.to_s.squish == value.to_s.squish
  end

  private

  def typed?(text)
    ctx.scratch.scope == :submit && text.length <= TYPE_LIMIT
  end
end
