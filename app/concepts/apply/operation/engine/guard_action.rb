# frozen_string_literal: true

# The one obstruction guard around a browser action (design §7.3), for the widgets (SetFieldValue) and, from phase
# 3b, the Navigator's executor and the recipe interpreter:
#
#   1. RunGates(:after_action) on a fresh snapshot (a late cookie banner is clicked away, a sign-in wall or a visible
#      captcha stops the run) BEFORE the action;
#   2. `action.call`;
#   3. on ApplyMate::Client::Browser::Obstructed (another element intercepts the pointer, the target never became
#      visible / enabled / stable / editable): the gates once more and ONE retry; a second Obstructed ->
#      Halt(:target_obstructed, detail: reason).
#
# Termination: at most two attempts. model = the action's return value.
class Apply::Operation::Engine::GuardAction < ApplyMate::Operation::Base
  def perform!(ctx:, action:, **)
    skip_authorize
    run_gates(ctx)
    self.model = action.call
  rescue ApplyMate::Client::Browser::Obstructed => e
    ctx.trace(:obstructed, reason: e.reason, retry: true)
    self.model = retry_once(ctx, action)
  end

  private

  def retry_once(ctx, action)
    run_gates(ctx)
    action.call
  rescue ApplyMate::Client::Browser::Obstructed => e
    ctx.trace(:obstructed, reason: e.reason, retry: false)
    raise Apply::Operation::Engine::Halt.new(:target_obstructed, detail: e.reason)
  end

  def run_gates(ctx)
    snapshot = ctx.session.snapshot_all(markers: Apply::Platform::Registry.dom_markers)
    Apply::Operation::Engine::RunGates.call(ctx:, event: :after_action, snapshot:)
  end
end
