# frozen_string_literal: true

# A wizard page after a Next click (design §7.4, `ctx.answer_followups!` / `ctx.inventory.discover_new!`), called by
# Stage::FillFields inside the submit scope:
#
#   1. the page's fields: BuildFieldInventory on a fresh snapshot (FormElements.snapshot unless the caller passes the
#      one it ran the after_action gates on), reconciled with ctx.fields by ReconcileFields(strict: false): a known
#      field present now takes its fresh target under its stored id; fields of earlier pages stay in the list without
#      a target; fresh fields nobody knew are new and get `page:` (Field#later_page?). Ids ("f_<signature>_<ordinal>",
#      platform keys) are stable across pages, so the stored answers apply to them.
#   2. new fields -> ctx.scratch.followup_calls += 1; more than MAX_FOLLOWUP_ANSWER_CALLS -> Halt(:wizard_too_long,
#      detail: 'follow-up answers'). A new field that already has an answer (an earlier attempt's follow-up, a review
#      edit) is not asked again, so a resumed run after an approved review reproduces the approved answers. The rest
#      go through Answer::Resolve(fields:) - ONE AI call for the page at most, through CallAi (this runs inside the
#      submit lease; CallAi bounds a browser-backed integration's local Chrome and sizes its timeout to the client's
#      latency). Answer::ExtractFacts is NOT called here.
#   3. ctx.fields = the reconciled list; persisted with the merged answers (ctx.persist!) when anything was new.
#
# model = the fields on this page now (present in the DOM), in the platform's fill_order. Stage::FillFields leaves out
# the ones it already filled on an earlier page.
class Apply::Operation::Engine::AnswerFollowups < ApplyMate::Operation::Base
  # One answer call per wizard page plus two for fields a page reveals conditionally (design §7.4).
  MAX_FOLLOWUP_ANSWER_CALLS = Apply::Operation::Stage::FillFields::MAX_WIZARD_PAGES + 2

  def perform!(ctx:, page:, snapshot: nil, **)
    skip_authorize
    snapshot ||= Apply::Operation::Engine::FormElements.snapshot(ctx)
    fresh = Apply::Operation::Engine::BuildFieldInventory.call(ctx:, snapshot:).model
    known = Array(ctx.fields).index_by(&:id)
    reconciled = Apply::Operation::Engine::ReconcileFields.call(stored: known.values, fresh:, strict: false)
    fields = reconciled.model.map { |field| known.key?(field.id) ? field : field.with(page:) }
    new_fields = fields.reject { |field| known.key?(field.id) }
    fields = answer!(ctx, fields, new_fields) if new_fields.any?
    ctx.fields = fields
    ctx.trace(:wizard_fields, page:, total: fields.size, new: new_fields.map(&:id))
    present = reconciled[:present]
    self.model = ctx.platform.fill_order(fields.select { |field| present.include?(field.id) })
  end

  private

  # Returns the fields with the semantics Resolve classified; persists them with the merged answers.
  def answer!(ctx, fields, new_fields)
    ctx.scratch.followup_calls += 1
    if ctx.scratch.followup_calls > MAX_FOLLOWUP_ANSWER_CALLS
      raise Apply::Operation::Engine::Halt.new(:wizard_too_long, detail: 'follow-up answers')
    end

    answers = ctx.apply.answers || {}
    unanswered = new_fields.reject { |field| answers.key?(field.id) }
    if unanswered.any?
      resolved = Apply::Operation::Answer::Resolve.call(ctx:, fields: unanswered)
      answers = answers.merge(resolved.model)
      classified = resolved[:fields].index_by(&:id)
      fields = fields.map { |field| classified.fetch(field.id, field) }
    end
    ctx.persist!(answers:, fields: fields.map(&:to_h))
    fields
  end
end
