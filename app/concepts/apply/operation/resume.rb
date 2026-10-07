# frozen_string_literal: true

# Puts a failed / unsupported / needs_human apply back on the queue. Allowed only while no submit claim exists
# and no sibling apply of the same user + vacancy has claimed or submitted (Apply#resumable?,
# Apply.submitted_sibling_of): re-running this one would send a second application, and the open-claim index
# does not catch it once the sibling is submitted. The state-guarded UPDATE repeats both checks (NOT EXISTS),
# closing the race with a concurrent cancel, claim or sibling submit; index_applies_one_active_per_vacancy
# refuses it while a sibling is still active.
# `failure` is kept on purpose: the timeline shows it as the previous attempt, the next halt overwrites it.
class Apply::Operation::Resume < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(Apply).includes(:vacancy).find(params[:id])
    authorize! model, :resume?
    refuse! unless model.resumable?

    requeue!

    Apply::Operation::Engine::Enqueue.call(apply: model)
    model.touch_user_applies_changed_at!
    Apply::Operation::Engine::Broadcast.call(apply: model)
    notice(I18n.t('apply.resume.success'))
  end

  private

  def requeue!
    updated = Apply.transaction do
      Apply.where(id: model.id, state: Apply::RESUMABLE_STATES, submit_claimed_at: nil)
           .where(Apply.submitted_sibling_of(model).arel.exists.not)
           .update_all(state: Apply.states.fetch(:queued), stage: nil, updated_at: Time.current)
    end
    refuse! if updated.zero?
  rescue ActiveRecord::RecordNotUnique
    # Another apply for the same vacancy is active (index_applies_one_active_per_vacancy).
    reject!(I18n.t('apply.create.already_active'))
  end

  def refuse!
    reject!(I18n.t('apply.resume.already_submitted')) if Apply.submitted_sibling_of(model).exists?
    reject!(I18n.t('apply.resume.not_allowed'))
  end

  def reject!(message)
    add_error(:base, message)
    raise ActiveRecord::RecordInvalid
  end
end
