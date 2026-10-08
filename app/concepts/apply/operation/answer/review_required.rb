# frozen_string_literal: true

# Does the run stop for the user's approval (design §8.2)? Only when there is a reason AND the user has not already
# approved exactly these answers: the approval is bound to the digest of what they saw, so any later change re-opens
# the review. model = Boolean, result[:reasons] = the ReviewReasons.
class Apply::Operation::Answer::ReviewRequired < ApplyMate::Operation::Base
  def perform!(ctx:, **)
    skip_authorize
    reasons = Apply::Operation::Answer::ReviewReasons.call(ctx:).model
    result[:reasons] = reasons
    approved = ctx.apply.answers_approved_digest == Apply::Operation::Answer::Digest.call(answers: ctx.apply.answers).model
    self.model = reasons.any? && !approved
  end
end
