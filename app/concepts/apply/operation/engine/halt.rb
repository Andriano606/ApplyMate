# frozen_string_literal: true

# A run stops on purpose: the code says why, the kind says which lifecycle state it lands in.
# Raised by steps (and by the Runner for :deadline / mapped exceptions); recorded by
# Apply::Operation::Engine::Lifecycle::RecordHalt, which applies the claim rule on top of #state.
#
# CODES is the single code -> kind map and KIND_STATE the single kind -> state map. Later phases only ADD
# producers of existing codes (or new rows here); the i18n spec iterates CODES, so every code needs
# apply.failure.<code> and apply.failure_hint.<code> in uk and en. See .ai/docs/apply_engine.md.
class Apply::Operation::Engine::Halt < StandardError
  CODES = {
    worker_lost: :transient, deadline: :transient, browser_crashed: :transient, capacity: :transient,
    budget_exhausted: :permanent, ai_budget_exhausted: :permanent, ai_lifetime_cap: :permanent, stuck: :permanent,
    invalid_ai_output: :permanent, required_field_unfillable: :permanent, no_widget_driver: :permanent,
    target_not_found: :permanent, target_obstructed: :permanent, validation_rejected: :permanent,
    invalid_record: :permanent, unexpected_error: :permanent, review_expired: :permanent, human_timeout: :permanent,
    legacy_failure: :permanent, # backfilled failed_* rows of the pre-engine status enum
    login_required: :unsupported, closed_posting: :unsupported, bot_wall: :unsupported, not_a_form: :unsupported,
    no_application_path: :unsupported, external_messenger: :unsupported, private_address: :unsupported,
    wizard_too_long: :unsupported,
    captcha_challenge: :needs_human, email_code: :needs_human, missing_profile_fact: :needs_human,
    session_expired: :needs_human, ai_integration_cannot_navigate: :needs_human,
    manual_apply_required: :needs_human, # design §18: Google Forms, visible captcha -> "apply yourself"
    already_claimed: :unverified, outcome_unknown: :unverified,
    review: :review, already_applied: :review
  }.freeze

  KIND_STATE = {
    transient: :failed, permanent: :failed, unsupported: :unsupported, needs_human: :needs_human,
    unverified: :submit_unverified, review: :needs_review
  }.freeze

  # The only codes that may release a submit claim, and only when raised with definitive: true.
  CLAIM_RELEASING = %i[session_expired validation_rejected].freeze

  attr_reader :code, :detail

  def initialize(code, detail: nil, definitive: false)
    @code = code.to_sym
    raise ArgumentError, "Unknown halt code #{code}" unless CODES.key?(@code)

    @detail = detail
    @definitive = definitive
    super("#{@code}: #{detail}")
  end

  def kind
    CODES.fetch(code)
  end

  def state
    KIND_STATE.fetch(kind)
  end

  # Only a verifier with deterministic proof that nothing was accepted may release the claim.
  def releases_claim?
    @definitive && CLAIM_RELEASING.include?(code)
  end
end
