# frozen_string_literal: true

# Stable identity of a form field across page loads and SPA re-renders — the
# key recipes and role mappings are stored under. Built from semantic traits
# only: position is deliberately excluded (reordering fields must not invalidate
# a recipe), and digit suffixes are stripped (Vue/React generate ids like
# input-33 that change every load). Collisions inside one form are acceptable —
# consumers store arrays, not hashes.
module Apply::FieldFingerprint
  def self.call(field)
    field = field.to_h.stringify_keys
    parts = [
      field['tag'],
      field['type'],
      field['autocomplete'],
      normalize(field['accessible_name'].presence || field['label']),
      normalize(field['name'])
    ]
    Digest::SHA1.hexdigest(parts.join('|'))
  end

  def self.normalize(value)
    value.to_s.downcase.strip.gsub(/\s+/, ' ').sub(/[-_]?\d+\z/, '')
  end
end
