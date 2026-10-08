# frozen_string_literal: true

# The outcome of the submit click (design §11.4): Engine::VerifySubmit's verdict.
#
#   submitted -> a masked full-page screenshot on applies.screenshot; the Runner's Finish writes completed and
#                submitted_at
#   rejected  -> Halt(:validation_rejected, definitive: true): the form is still there with field errors and no
#                mutation was accepted, so the claim is released
#   unknown   -> Halt(:outcome_unknown): submit_unverified, the user says whether it was sent
class Apply::Operation::Stage::Verify < Apply::Operation::Stage::Base
  stage :verify

  private

  def run!(ctx:, apply:, **)
    verdict = Apply::Operation::Engine::VerifySubmit.call(ctx:).model
    ctx.trace(:verdict, status: verdict.status.to_s, **verdict.evidence)
    case verdict.status
    when :submitted then attach_screenshot(ctx, apply)
    when :rejected then halt!(:validation_rejected, detail: "field errors: #{verdict.evidence['field_errors'].join(', ')}",
                                                     definitive: true)
    else halt!(:outcome_unknown, detail: "signals #{verdict.evidence['count']}/#{verdict.evidence['min_signals']}")
    end
    step_result(status: verdict.status.to_s, signals: verdict.evidence['signals'])
  end

  # Evidence only: a failing screenshot must not turn an accepted application into a failure.
  def attach_screenshot(ctx, apply)
    png = ctx.session.screenshot(full_page: true, mask_fillable: true)
    apply.screenshot.attach(io: StringIO.new(png), filename: "screenshot_#{apply.id}.png", content_type: 'image/png')
  rescue StandardError => e
    ctx.trace(:screenshot_failed, error: e.class.name)
    Rails.error.report(e, handled: true, context: { apply: apply.hashid, stage: 'verify' })
  end
end
