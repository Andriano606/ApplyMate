# frozen_string_literal: true

# An answer value that is a file, not text: the widget uploads the apply's own file (today the generated CV).
# Stored in applies.answers as { 'file' => 'cv' } (#as_json); .parse reads it back.
class Apply::Operation::Answer::FileRef < Data.define(:kind)
  def self.cv
    new(kind: 'cv')
  end

  def self.parse(value)
    new(kind: value['file']) if value.is_a?(Hash) && value['file'].present?
  end

  def cv?
    kind == 'cv'
  end

  def as_json(*)
    { 'file' => kind }
  end
end
