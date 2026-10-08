# frozen_string_literal: true

# Builders for the answer pipeline specs (included in every spec by spec/rails_helper.rb).
module AnswerHelpers
  YES_NO = [ { 'label' => 'Yes', 'value' => 'true' }, { 'label' => 'No', 'value' => 'false' } ].freeze

  # An Apply::Field with every member nil except the usual ones; override anything.
  def answer_field(**overrides)
    attrs = Apply::Field.members.index_with { nil }.merge(
      id: 'q1', kind: 'text', label: 'Question', required: false, widget: 'text', ordinal: 0, source: 'snapshot',
      semantic: 'other'
    )
    Apply::Field.new(**attrs.merge(overrides))
  end

  def answer_entry(value, source: 'ai', confidence: 0.9)
    { 'value' => value, 'source' => source, 'confidence' => confidence }
  end
end
