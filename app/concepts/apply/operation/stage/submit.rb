# frozen_string_literal: true

# The one irreversible click (design §11.2), in this order:
#
#   1. ctx.remaining < SUBMIT_RESERVE -> Halt(:deadline) (the settle and the verify need the time; before the claim,
#      so Resume is safe)
#   2. a fresh snapshot: RunGates(:before_submit) (a visible captcha -> manual_apply_required), then the button
#      Engine::ClassifyAdvance picks inside the form root (the one locator, shared with FillFields' wizard loop): none
#      or an ambiguous set -> Halt(:target_not_found); a :next button (a wizard page FillFields did not consume) ->
#      Halt(:wizard_too_long, detail: 'next button at submit'); both before the claim
#   3. a trial click on that button inside GuardAction (Session#trial_click: every actionability check, no click): a
#      launcher or overlay covering it is dismissed by the gates and retried once, else Halt(:target_obstructed) -
#      still before the claim, so a click that could never land is not left as submit_unverified
#   4. NetTracker watches success_evidence[:submit_request][:url] (response bodies are captured only for requests
#      that start after the watch, so it must precede the click)
#   5. CaptureArtifact(:before_submit) (masked screenshot on this step's row)
#   6. ctx.scratch.submit_baseline = SubmitBaseline (the page signals that already hold: VerifySubmit ignores them);
#      ClaimSubmit (fenced; from here every halt is submit_unverified unless definitive)
#   7. ctx.scratch.claim_mark = network mark; trusted click; settle(:submit); RunGates(:after_submit)
class Apply::Operation::Stage::Submit < Apply::Operation::Stage::Base
  stage :submit

  # Seconds the settle (up to 15 s), the verify (evidence, AI up to 30 s) and the screenshot need after the click.
  SUBMIT_RESERVE = 120

  private

  def run!(ctx:, **)
    halt!(:deadline, detail: 'no time left for the submit') if ctx.remaining < SUBMIT_RESERVE

    session = ctx.session
    snapshot = Apply::Operation::Engine::FormElements.snapshot(ctx)
    Apply::Operation::Engine::RunGates.call(ctx:, event: :before_submit, snapshot:)
    button = submit_button(ctx, snapshot)
    Apply::Operation::Engine::GuardAction.call(ctx:, action: -> { session.trial_click(button.target) })
    watch(ctx)
    Apply::Operation::Engine::CaptureArtifact.call(ctx:, step_record: ctx.scratch.step_record, label: :before_submit)
    ctx.scratch.submit_baseline = Apply::Operation::Engine::SubmitBaseline.call(ctx:).model
    Apply::Operation::Engine::ClaimSubmit.call(ctx:)
    ctx.scratch.claim_mark = session.network_mark
    session.click(button.target)
    session.settle(:submit)
    Apply::Operation::Engine::RunGates.call(ctx:, event: :after_submit,
                                            snapshot: session.snapshot_all(markers: Apply::Platform::Registry.dom_markers))
    step_result(button: button.name)
  end

  # The :final ClassifyAdvance::Advance.
  def submit_button(ctx, snapshot)
    advance = Apply::Operation::Engine::ClassifyAdvance.call(ctx:, snapshot:).model
    halt!(:target_not_found, detail: 'submit buttons in the form: 0') if advance.nil?
    halt!(:wizard_too_long, detail: 'next button at submit') if advance.kind == :next

    advance
  end

  def watch(ctx)
    url = ctx.platform.success_evidence.dig(:submit_request, :url)
    ctx.session.network_watch(url) if url
  end
end
