# frozen_string_literal: true

# Stops the run for the user's review when Answer::ReviewRequired says so (design §8.2): Halt(:review) lands in
# needs_review with the reasons in failure.detail, which the review form lists. Always runs (input_digest nil): it
# is cheap, and an approval is only valid for the exact answers it was given for.
class Apply::Operation::Stage::ReviewGate < Apply::Operation::Stage::Base
  stage :review

  private

  def run!(ctx:, **)
    required = Apply::Operation::Answer::ReviewRequired.call(ctx:)
    reasons = required[:reasons]
    step_result(reasons: reasons.map(&:to_s))
    halt!(:review, detail: reasons.join(',')) if required.model
  end
end
