# frozen_string_literal: true

# A native slider (<input type=range>, the `range` kind). Playwright cannot `fill` it, so it is driven with trusted keys:
# read min / step from the control (read_value probe; defaults 0 and 1), click it, Home (-> min), then ArrowRight
# n = round((value - min) / step) times, at most MAX_STEPS (a 0..100 000 slider is not walked key by key; the
# read-back then disagrees and the fallback runs). Fallback: `fill` a companion <input type=number> in the field root
# (or the slider's parent) when one is visible. Read-back: `.value`, else aria-valuenow, numerically equal to the
# answer.
class Apply::Widget::Range < Apply::Widget::Base
  MAX_STEPS = 200
  COMPANION = 'input[type=number]'

  def self.handles?(field)
    field.kind == 'range'
  end

  def write(value)
    wanted = number(value) || raise(Apply::Widget::Mismatch.new(field:, wanted: value, read_back: nil))
    raw = session.probe(:read_value, target)
    min = number(raw['min']) || 0.0
    step = number(raw['step'])
    step = 1.0 unless step&.positive?
    presses = ((wanted - min) / step).round.clamp(0, MAX_STEPS)
    session.click(target)
    session.press(target, 'Home')
    presses.times { session.press(target, 'ArrowRight') }
  end

  def fallback_write(value)
    scope = root_selector.presence || parent_css
    return if scope.nil?

    companion = scoped_target("#{scope} #{COMPANION}")
    return unless session.present?(companion, visibility: :required)

    session.fill(companion, value.to_s)
    true
  end

  def read
    raw = session.probe(:read_value, target)
    ReadBack.new(displayed: raw['value'].presence || raw['aria_valuenow'], invalid: raw['invalid'] == true,
                 error_text: raw['error_text'])
  end

  def accepts?(read_back, value)
    shown = number(read_back.displayed)
    !read_back.invalid && !shown.nil? && shown == number(value)
  end

  private

  def number(value)
    Float(value.to_s.strip.tr(',', '.'), exception: false)
  end
end
