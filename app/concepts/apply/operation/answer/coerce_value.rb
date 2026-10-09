# frozen_string_literal: true

# The ONE "is this value a valid answer for this field" check, shared by the AI answers (Answer::Resolve) and the
# user's edits (ApproveReview). model = the value in the field's own terms, or nil for blank:
#   option kinds   the matched option's label (a list for Apply::Field#multi_valued?); an unknown option is an error
#                  (a field with dynamic or unknown options takes the text as given)
#   checkbox       true / false from yes / true / 1 / так ...
#   number, range  a number
#   anything else  text, cut to max_length; after a fixed dial-code prefix ("+380") an international phone is typed
#                  without that code (#after_prefix)
# A required field that ends up blank (or an unticked checkbox) is an error too. result[:error] = the reason, nil when
# the value is fine.
class Apply::Operation::Answer::CoerceValue < ApplyMate::Operation::Base
  DIAL_CODE = /\A\+(\d{1,4})\z/
  INTERNATIONAL = /\A\s*(?:\+|00)/

  def perform!(field:, value:, **)
    skip_authorize
    @field = field
    self.model = coerce(value)
    result[:error] ||= 'is required' if field.required && model.blank?
  end

  private

  attr_reader :field

  def coerce(value)
    return if value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.blank?)
    return reject('is not a plain value') if value.is_a?(Hash)
    return option(value) if field.option_kind? && field.options.is_a?(Array)
    return checkbox(value) if field.kind == 'checkbox'
    return number(value) if %w[number range].include?(field.kind)

    text(value)
  end

  def option(value)
    labels = Array(value).map { |wanted| matched_label(wanted) }
    return if labels.include?(nil)

    field.multi_valued? ? labels : labels.first
  end

  def matched_label(wanted)
    option = Apply::Operation::Engine::MatchOption.call(candidates: field.options, wanted: wanted.to_s).model
    return option['label'] if option

    reject("#{wanted.to_s.truncate(60).inspect} is not one of the options")
  end

  def checkbox(value)
    return true if value == true || Apply::Operation::Engine::MatchOption.truthy?(value)
    return false if value == false || Apply::Operation::Engine::MatchOption.falsy?(value)

    reject('is not a yes/no value')
  end

  def number(value)
    number = Float(value.to_s.strip.tr(',', '.'))
    number.finite? && number == number.to_i ? number.to_i : number
  rescue ArgumentError, TypeError
    reject('is not a number')
  end

  def text(value)
    text = after_prefix((value.is_a?(Array) ? value.join(', ') : value.to_s).strip)
    field.max_length.to_i.positive? ? text[0, field.max_length.to_i].rstrip : text
  end

  # A value typed after a fixed dial-code prefix ("+380" before the input) is the national part only:
  # "+380 67 123 45 67" -> "671234567", else the code is typed twice. Only an international value ("+" / "00") whose
  # digits start with the prefix's code loses it; any other value (national, another country's) stays as given.
  def after_prefix(text)
    code = field.prefix.to_s.delete(' ()-')[DIAL_CODE, 1]
    return text unless code && text.match?(INTERNATIONAL)

    digits = text.sub(INTERNATIONAL, '').gsub(/\D/, '')
    digits.start_with?(code) && digits.length > code.length ? digits.delete_prefix(code) : text
  end

  def reject(message)
    result[:error] = message
    nil
  end
end
