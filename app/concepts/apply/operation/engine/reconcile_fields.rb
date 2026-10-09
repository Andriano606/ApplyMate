# frozen_string_literal: true

# Stored fields against freshly discovered ones (design §7.1): every stored field is matched to a fresh one by id,
# then by (signature, ordinal); a stored target is never reused (targets are valid for one page state of one session)
# and never used as identity. A matched field is the fresh one (target, widget, DOM state) under the stored id,
# keeping the stored semantic, condition and wizard page (AnswerFields / AnswerFollowups wrote them; the answers are
# keyed by that id).
#
# strict: true (Stage::DiscoverFields reconcile: true, the submit scope's first page):
#   stored required field without a fresh match -> Halt(:target_not_found, detail: id)
#   stored optional field without a fresh match -> dropped (not on the page this time)
#   stored field of a later wizard page         -> kept without a target (Field#later_page?: its page is behind a Next
#                                                  button; Engine::AnswerFollowups gives it a target once it shows)
# strict: false (Engine::AnswerFollowups, a later wizard page in the same session):
#   any stored field without a fresh match      -> kept without a target (fields of earlier pages are legitimately gone)
#
# Fresh fields nobody matched are appended (AnswerFollowups answers them; on the first page FillFields leaves them
# empty when optional and halts required_field_unfillable when required).
#
# model = [Apply::Field], stored order first; result[:present] = ids of the fields on the page now (matched or new).
class Apply::Operation::Engine::ReconcileFields < ApplyMate::Operation::Base
  def perform!(stored:, fresh:, strict: true, **)
    skip_authorize
    remaining = fresh.dup
    present = []
    merged = stored.filter_map do |old|
      match = take(remaining) { |field| field.id == old.id } ||
              take(remaining) { |field| field.signature == old.signature && field.ordinal == old.ordinal }
      next unmatched(old, strict) if match.nil?

      present << old.id
      merge(old, match)
    end
    fields = merged + remaining
    raise Apply::Operation::Engine::Halt.new(:unexpected_error, detail: 'field id collision') if fields.uniq(&:id).size != fields.size

    result[:present] = present + remaining.map(&:id)
    self.model = fields
  end

  private

  def take(fields, &)
    index = fields.index(&)
    index && fields.delete_at(index)
  end

  def merge(old, fresh)
    fresh.with(id: old.id, semantic: old.semantic || fresh.semantic, condition: old.condition || fresh.condition,
               page: old.page)
  end

  def unmatched(old, strict)
    return old.with(target: nil) if !strict || old.later_page?
    raise Apply::Operation::Engine::Halt.new(:target_not_found, detail: old.id) if old.required
  end
end
