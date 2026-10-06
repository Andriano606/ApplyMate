# frozen_string_literal: true

# One entry of Apply#inputs / Apply#filled_inputs ({ name, tag, type, label, placeholder, value, options }).
# The single place that decides how a scraped form field is labelled and classified.
class Apply::FormField
  SKIP_TYPES = %w[hidden submit button].freeze

  def self.wrap(fields)
    Array(fields).map { |field| new(field) }
  end

  def initialize(field)
    @field = field.to_h.stringify_keys
  end

  # Human-written text of the field (label, then placeholder); nil when the form gave none.
  def label
    [ @field['label'], @field['placeholder'] ].map { |text| text.to_s.strip }.find(&:present?)
  end

  def display_label
    label || @field['name'].to_s
  end

  def placeholder
    @field['placeholder'].presence
  end

  def value
    @field['value'].to_s.strip
  end

  def visible?
    SKIP_TYPES.exclude?(@field['type'])
  end

  def textarea?
    @field['tag'] == 'textarea' || @field['type'] == 'textarea'
  end

  def select?
    @field['tag'] == 'select' || @field['type'] == 'select'
  end

  def file?
    @field['type'] == 'file'
  end

  # An open question the user can ask the AI to answer (VacancyQuestion).
  def question?
    textarea? && label.present?
  end
end
