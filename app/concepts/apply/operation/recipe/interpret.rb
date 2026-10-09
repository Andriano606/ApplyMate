# frozen_string_literal: true

# Runs a recipe (op hashes or Apply::Recipe::Op objects; design §12) in the open session: every op is parsed first
# (an invalid stored recipe touches nothing), ctx.form_root is cleared, then per op: fence check -> (for an
# opens_tab? op) Engine::AdoptNewTab.watch -> op.perform! -> Engine::Observe(op.gate_event) -> trace `recipe_op`;
# a tab the op opened is adopted (Engine::AdoptNewTab) unless the next op is a stored switch_tab, observed and
# inserted into the model. TargetNotFound -> Drift(op) (a stale locator is drift, not target_not_found).
#
# verify_form! (a recipe whose last op reaches_form?, i.e. wait_for): ctx.form_root must be set AND the elements in it
# must pass R2 (Engine::AssessFormLikeness over Engine::FormElements); otherwise the root is cleared and Drift(last op)
# is raised. Every Drift carries the ops performed before it (Drift#performed).
#
# model = the performed op hashes. Termination: one pass over a finite list, <= 1 adopted tab per op, every wait
# clamped to the scope deadline.
class Apply::Operation::Recipe::Interpret < ApplyMate::Operation::Base
  def perform!(ctx:, ops:, **)
    skip_authorize
    @ctx = ctx
    parsed = ops.map { |op| op.is_a?(Apply::Recipe::Op::Base) ? op : Apply::Recipe::Op::Base.parse!(op) }
    ctx.form_root = nil
    @performed = []
    parsed.each_with_index { |op, index| step(op, parsed[index + 1]) }
    verify_form!(parsed.last)
    self.model = @performed
  rescue Apply::Operation::Recipe::Drift => e
    raise Apply::Operation::Recipe::Drift.new(op: e.op, detail: e.detail, performed: @performed.dup)
  end

  private

  attr_reader :ctx

  def step(op, next_op)
    watch = run(op)
    @performed << op.to_h
    return if watch.nil? || next_op.is_a?(Apply::Recipe::Op::SwitchTab)

    tab = Apply::Operation::Engine::AdoptNewTab.call(ctx:, **watch).model
    return unless tab

    observe(tab)
    @performed << tab.to_h
  end

  def run(op)
    ctx.check_fence!
    watch = drift_on_missing(op) do
      before = Apply::Operation::Engine::AdoptNewTab.watch(ctx, op.target) if op.opens_tab?
      op.perform!(ctx)
      before
    end
    observe(op)
    watch
  end

  def drift_on_missing(op)
    yield
  rescue ApplyMate::Client::Browser::TargetNotFound => e
    raise Apply::Operation::Recipe::Drift.new(op:, detail: e.message.truncate(200))
  end

  def observe(op)
    match = Apply::Operation::Engine::Observe.call(ctx:, event: op.gate_event).model
    ctx.trace(:recipe_op, op: op.class.op, platform: match.key, url: ctx.session.current_url)
  end

  def verify_form!(last_op)
    return unless last_op&.reaches_form?
    raise Apply::Operation::Recipe::Drift.new(op: last_op, detail: 'form root not set') unless ctx.form_root

    snapshot = Apply::Operation::Engine::FormElements.snapshot(ctx)
    elements = Apply::Operation::Engine::FormElements.call(ctx:, snapshot:).model
    verdict = Apply::Operation::Engine::AssessFormLikeness.call(elements:).model
    ctx.trace(:form_likeness, accepted: verdict.accepted, reason: verdict.reason, fillable: verdict.fillable)
    return if verdict.accepted

    ctx.form_root = nil
    raise Apply::Operation::Recipe::Drift.new(op: last_op, detail: "not an application form (#{verdict.reason})")
  end
end
