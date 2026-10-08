# frozen_string_literal: true

# A captcha a person would have to solve (design §18 item 5: no solver services): the snapshot's captcha list (any
# frame) contains a VISIBLE_KINDS widget -> Halt(:manual_apply_required, detail: :captcha), the "apply yourself"
# needs_human state before the claim (after it, the claim rule makes it submit_unverified). Invisible / score-based
# kinds (recaptcha_invisible, hcaptcha_invisible, turnstile_invisible) never stop a run.
class Apply::Gate::VisibleCaptcha < Apply::Gate::Base
  VISIBLE_KINDS = %w[recaptcha recaptcha_challenge hcaptcha turnstile].freeze

  def self.events
    %i[after_action before_submit]
  end

  def call(_ctx, snapshot: nil, **)
    return if snapshot.nil?

    kinds = snapshot.frames.flat_map { |frame| Array(frame['captcha']) } & VISIBLE_KINDS
    halt!(:manual_apply_required, detail: :captcha) if kinds.any?
  end
end
