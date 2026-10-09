# frozen_string_literal: true

# Text-like inputs and textareas (dates are Widget::DateInput's): `fill`; in the submit scope (the lease that clicks
# submit, where invisible captchas score the interaction) `type` with 40-90 ms between keys, after clearing the field.
# Fallback: clear and `type` (a React-controlled input that "ate" the filled value usually takes typed keys).
# Widget::ContentEditable inherits the typing rule and the read-back (#accepts?).
class Apply::Widget::Text < Apply::Widget::Base
  KINDS = %w[text email tel url number textarea].freeze
  # Longest answer typed key by key; a longer one is filled (pasted): at 40-90 ms per key a 1 000-character letter
  # would eat a minute of the submit scope (SCOPE_DEADLINE 8 min, SUBMIT_RESERVE 120 s).
  TYPE_LIMIT = 300
  # What an input mask may leave around the digits of a phone: spaces (also no-break ones), dots, dashes,
  # parentheses, one leading "+".
  PHONE_TEXT = /\A[\s\p{Zs}]*\+?[\d\s\p{Zs}().\p{Pd}]*\z/
  # The same for a plain number in a text input, without dots (a decimal separator is meaningful there).
  NUMBER_TEXT = /\A[\s\p{Zs}]*\+?[\d\s\p{Zs}()\p{Pd}]*\z/

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

  # THE read-back equality of text-like controls (ContentEditable inherits it). Text must stick exactly: option-style
  # matching would accept "Jane" for "Jane Doe" (maxlength). Only whitespace is normalised (a single-line input drops
  # line breaks, a textarea normalises \r\n). A masked number (#digits_only?) is compared by its digits instead: the
  # site's mask may add spaces, dashes, dots, parentheses, a "+" and the fixed dial code it shows beside the input
  # (field.prefix "+380" -> "380"), but every digit typed must be there, in order, and nothing else.
  def accepts?(read_back, value)
    return false if read_back.invalid

    wanted = value.to_s
    shown = read_back.displayed.to_s
    return shown.squish == wanted.squish unless digits_only?(wanted)

    same_digits?(shown, wanted)
  end

  private

  # A tel / phone field, or a value that is only digits and mask separators (a number in a text input): a mask may
  # reformat it. A value with a decimal separator stays exact ("1.5" is not "15"), except on a phone field.
  def digits_only?(wanted)
    return false unless wanted.match?(/\d/)
    return wanted.match?(PHONE_TEXT) if field.kind == 'tel' || field.semantic == 'phone'

    wanted.match?(NUMBER_TEXT)
  end

  def same_digits?(shown, wanted)
    return false unless shown.match?(PHONE_TEXT)

    digits = shown.gsub(/\D/, '')
    wanted_digits = wanted.gsub(/\D/, '')
    code = field.prefix.to_s.gsub(/\D/, '')
    digits == wanted_digits || (code.present? && digits == code + wanted_digits)
  end

  def typed?(text)
    ctx.scratch.scope == :submit && text.length <= TYPE_LIMIT
  end
end
