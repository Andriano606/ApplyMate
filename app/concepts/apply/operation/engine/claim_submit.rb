# frozen_string_literal: true

# Takes the submit claim right before the irreversible POST/click (design §11.2):
#   UPDATE applies SET submit_claimed_at = now() WHERE id AND run_token AND submit_claimed_at IS NULL
#                                                AND submitted_at IS NULL
# No row (already claimed or submitted) or a unique violation on index_applies_one_open_claim_per_vacancy
# (another non-cancelled apply of this user/vacancy holds an open claim) -> Halt(:already_claimed), which the
# claim rule records as submit_unverified. After this, every halt of the run lands in submit_unverified
# unless a definitive rejection releases the claim (Lifecycle::RecordHalt).
class Apply::Operation::Engine::ClaimSubmit < ApplyMate::Operation::Base
  UNCLAIMED = 'submit_claimed_at IS NULL AND submitted_at IS NULL'

  def perform!(ctx:, **)
    skip_authorize
    ctx.check_fence!
    raise Apply::Operation::Engine::Halt.new(:already_claimed) if claim(ctx).zero?

    self.model = true
  end

  private

  # The savepoint keeps a unique violation from aborting an enclosing transaction (and the spec transaction).
  def claim(ctx)
    Apply.transaction(requires_new: true) do
      Apply::Operation::Engine::FencedUpdate.call(ctx:, attributes: { submit_claimed_at: Time.current },
                                                  extra_condition: UNCLAIMED).model
    end
  rescue ActiveRecord::RecordNotUnique
    0
  end
end
