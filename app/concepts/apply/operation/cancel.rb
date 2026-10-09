# frozen_string_literal: true

# Cancels an apply that no run owns. Rotating run_token fences a job that starts late (StartContext also
# refuses state cancelled). A running apply must finish or be reaped first; submit_unverified must be resolved
# through MarkOutcome.
class Apply::Operation::Cancel < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(Apply).includes(:vacancy).find(params[:id])
    authorize! model, :cancel?

    updated = Apply.where(id: model.id, state: Apply::CANCELLABLE_STATES)
                   .update_all(state: :cancelled, run_token: SecureRandom.uuid, stage: nil, updated_at: Time.current)
    if updated.zero?
      add_error(:base, I18n.t('apply.cancel.not_allowed'))
      raise ActiveRecord::RecordInvalid
    end

    model.touch_user_applies_changed_at!
    Apply::Operation::Engine::Broadcast.call(apply: model)
    notice(I18n.t('apply.cancel.success'))
  end
end
