# frozen_string_literal: true

class Apply::Component::FilledFormPreview < ApplyMate::Component::Base
  SKIP_TYPES = %w[hidden submit button].freeze

  def initialize(filled_inputs:)
    @filled_inputs = Array(filled_inputs)
  end

  private

  def visible_inputs
    @filled_inputs.reject { |f| SKIP_TYPES.include?(f['type']) }
  end

  def label_for(field)
    [ field['label'], field['placeholder'], field['name'] ]
      .map(&:to_s)
      .map(&:strip)
      .reject(&:empty?)
      .first || field['name'].to_s
  end

  def value_for(field)
    field['value'].to_s.strip
  end

  def textarea?(field)
    field['tag'] == 'textarea' || field['type'] == 'textarea'
  end

  def file?(field)
    field['type'] == 'file'
  end

  def select?(field)
    field['tag'] == 'select' || field['type'] == 'select'
  end
end
