# frozen_string_literal: true

# The submit session's fields against the stored ones (design §7.1): every stored field is matched to a fresh one by
# id, then by (signature, ordinal); a stored target is never reused (targets are valid for one session only) and
# never used as identity. A matched field is the fresh one (target, widget, DOM state) under the stored id, keeping
# the stored semantic and condition (AnswerFields wrote them; the answers are keyed by that id).
#
#   stored required field without a fresh match -> Halt(:target_not_found, detail: id)
#   stored optional field without a fresh match -> dropped (not on the page this time)
#   fresh fields nobody matched                 -> appended; FillFields leaves them empty when optional and halts
#                                                  required_field_unfillable when required (no answer exists for them;
#                                                  follow-up answers arrive with the wizards in phase 3b)
#
# model = [Apply::Field], stored order first.
class Apply::Operation::Engine::ReconcileFields < ApplyMate::Operation::Base
  def perform!(stored:, fresh:, **)
    skip_authorize
    remaining = fresh.dup
    merged = stored.filter_map do |old|
      match = take(remaining) { |field| field.id == old.id } ||
              take(remaining) { |field| field.signature == old.signature && field.ordinal == old.ordinal }
      next merge(old, match) if match
      raise Apply::Operation::Engine::Halt.new(:target_not_found, detail: old.id) if old.required
    end
    fields = merged + remaining
    raise Apply::Operation::Engine::Halt.new(:unexpected_error, detail: 'field id collision') if fields.uniq(&:id).size != fields.size

    self.model = fields
  end

  private

  def take(fields, &)
    index = fields.index(&)
    index && fields.delete_at(index)
  end

  def merge(old, fresh)
    fresh.with(id: old.id, semantic: old.semantic || fresh.semantic, condition: old.condition || fresh.condition)
  end
end
