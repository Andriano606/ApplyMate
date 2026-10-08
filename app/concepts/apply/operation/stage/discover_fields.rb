# frozen_string_literal: true

# The form's fields in the open session (design §7.1, §10.2): one snapshot of every frame with the form regions
# (Engine::FormElements.snapshot), RunGates(:after_goto) on it, Engine::BuildFieldInventory (snapshot + ctx.schema).
# `reconcile: true` (submit scope): Engine::ReconcileFields against the stored applies.fields (ids kept, fresh
# targets). The list is ctx.fields and is persisted as applies.fields.
#
# Survey scope: skipped on a later attempt while the match, the schema ids (sorted: a restored schema comes back in
# discovery order) and the platform registry are unchanged; restore rebuilds ctx.fields from applies.fields. Submit scope: always runs (targets are valid for one session).
class Apply::Operation::Stage::DiscoverFields < Apply::Operation::Stage::Base
  stage :discover

  def self.input_digest(ctx, reconcile: false, **)
    return if reconcile

    Digest::SHA256.hexdigest([ ctx.match&.to_h&.slice('key', 'captures'), Array(ctx.schema).map(&:id).sort,
                               Apply::Platform::Registry.fingerprint ].to_json)
  end

  def self.restore(ctx, _result)
    ctx.fields = ctx.apply.field_list
  end

  private

  def run!(ctx:, apply:, reconcile: false, **)
    snapshot = Apply::Operation::Engine::FormElements.snapshot(ctx)
    Apply::Operation::Engine::RunGates.call(ctx:, event: :after_goto, snapshot:)
    fresh = Apply::Operation::Engine::BuildFieldInventory.call(ctx:, snapshot:).model
    fields = reconcile ? Apply::Operation::Engine::ReconcileFields.call(stored: apply.field_list, fresh:).model : fresh
    ctx.fields = fields
    ctx.trace(:fields_discovered, total: fields.size, without_widget: fields.reject(&:widget).map(&:id))
    ctx.persist!(fields: fields.map(&:to_h))
    step_result(fields: fields.size)
  end
end
