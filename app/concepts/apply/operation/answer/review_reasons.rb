# frozen_string_literal: true

# Why a human should look at the answers before the submit (design §8.2). model = [Symbol]:
#   policy_always       users.review_policy == always                                   (a taste: review_policy never skips it)
#   unknown_platform    users.review_policy == unknown_platforms and the platform is unknown (a Generic form)
#   low_confidence      an AI answer with confidence < LOW_CONFIDENCE                    (safety)
#   approximate         an answer picked as the nearest option                          (safety)
#   consent_pending     a consent the user opted not to give automatically (auto_consent false)  (safety)
#   foreign_origin      the form lives on a registered domain unrelated to the vacancy  (safety)
#   duplicate           the same posting was already applied to and the user has not confirmed it (safety)
# The safety reasons apply whatever the review policy is.
class Apply::Operation::Answer::ReviewReasons < ApplyMate::Operation::Base
  LOW_CONFIDENCE = 0.5

  def perform!(ctx:, **)
    skip_authorize
    @ctx = ctx
    user = ctx.apply.user
    answers = (ctx.apply.answers || {}).values
    reasons = []
    reasons << :policy_always if user.review_policy_always?
    reasons << :unknown_platform if user.review_policy_unknown_platforms? && !ctx.platform_known?
    reasons << :low_confidence if answers.any? { |a| a['source'] == 'ai' && a['confidence'].to_f < LOW_CONFIDENCE }
    reasons << :approximate if answers.any? { |a| a['source'] == 'approximate' }
    reasons << :consent_pending if answers.any? { |a| a['source'] == 'policy_pending' }
    reasons << :foreign_origin unless Apply::Operation::Engine::CheckOrigin.call(ctx:).model
    reasons << :duplicate if duplicate?
    self.model = reasons
  end

  private

  attr_reader :ctx

  def duplicate?
    key = ctx.apply.apply_key
    key.present? && ctx.apply.duplicate_confirmed_at.nil? &&
      Apply::Operation::Engine::CheckApplyKey.previous_apply(ctx.apply, key).present?
  end
end
