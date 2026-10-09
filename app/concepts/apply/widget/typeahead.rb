# frozen_string_literal: true

# An ARIA-less typeahead (snapshot.js `typeahead`: a free-text input beside a suggestion container its script fills
# after typing, Lever's location input): BuildFieldInventory stores this key for such an `autocomplete` field (never
# picked by kind, handles? is false). Written like Widget::Autocomplete (type a prefix, pick the matching suggestion,
# else the first one as an approximate pick), with a shorter MAX_WAIT per prefix; when no suggestion appears at all
# the input is a plain text field after all and keeps the typed answer (read back as text).
class Apply::Widget::Typeahead < Apply::Widget::Autocomplete
  MAX_WAIT = 3

  def self.handles?(_field)
    false
  end

  def write(value)
    super
  rescue Apply::Widget::Mismatch
    @picked = nil
    session.fill(target, value.to_s)
  end
end
