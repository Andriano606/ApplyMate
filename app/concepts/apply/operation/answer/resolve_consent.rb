# frozen_string_literal: true

# A consent_required field (design §8.1, §18.3; a marketing_opt_in is never set, Answer::Resolve skips it):
#   consent_required  a checkbox -> true; an option field -> the option MatchOption finds for the affirm lexicon
#                     (a list when Apply::Field#multi_valued?). Source 'policy' when users.auto_consent (default true), else
#                     'policy_pending' (ReviewReasons: consent_pending). No affirmative option -> model nil and
#                     result[:reason] = :review (Answer::Resolve leaves the field to the user in the review form).
# model = { 'value' =>, 'source' =>, 'confidence' => } or nil.
class Apply::Operation::Answer::ResolveConsent < ApplyMate::Operation::Base
  def perform!(field:, user:, **)
    skip_authorize
    value = affirmative(field)
    if value.nil?
      result[:reason] = :review
      return
    end

    self.model = { 'value' => value, 'source' => user.auto_consent ? 'policy' : 'policy_pending', 'confidence' => 1.0 }
  end

  private

  def affirmative(field)
    return true if field.kind == 'checkbox'

    label = Apply::Operation::Answer::Classify.option_label_for(field, Apply::Operation::Answer::Classify::AFFIRM)
    return if label.nil?

    field.multi_valued? ? [ label ] : label
  end
end
