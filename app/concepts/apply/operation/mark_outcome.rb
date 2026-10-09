# frozen_string_literal: true

# The user tells us what really happened to an apply the engine cannot decide on its own: a submit it could not
# verify, or an application the user finished by hand. Every transition is a state-guarded UPDATE.
class Apply::Operation::MarkOutcome < ApplyMate::Operation::Base
  OUTCOMES = {
    'sent' => {
      from: %w[submit_unverified],
      confirm: false,
      updates: lambda { |_apply|
        { state: :completed, submitted_at: Time.current, submitted_via: 'engine' }
      }
    },
    # Releases the submit claim so a new apply for the vacancy can be created.
    'not_sent' => {
      from: %w[submit_unverified],
      confirm: true,
      updates: lambda { |apply|
        { state: :failed, submit_claimed_at: nil, failure: (apply.failure || {}).merge('resolved' => 'not_sent') }
      }
    },
    # The claim, if any, stays: it is the record that a submit may have happened.
    'manual' => {
      from: %w[needs_human unsupported failed submit_unverified],
      confirm: false,
      updates: lambda { |_apply|
        { state: :completed, submitted_at: Time.current, submitted_via: 'manual' }
      }
    }
  }.freeze

  def perform!(params:, current_user:, **)
    self.model = policy_scope(Apply).includes(:vacancy).find(params[:id])
    authorize! model, :mark_outcome?

    outcome = params[:outcome].to_s
    config = OUTCOMES[outcome]
    reject!(I18n.t('apply.mark_outcome.not_allowed')) if config.nil? || config[:from].exclude?(model.state)
    reject!(I18n.t('apply.mark_outcome.confirm_required')) if config[:confirm] && params[:confirm].to_s != '1'

    updated = Apply.where(id: model.id, state: config[:from])
                   .update_all(**config[:updates].call(model), updated_at: Time.current)
    reject!(I18n.t('apply.mark_outcome.not_allowed')) if updated.zero?

    model.touch_user_applies_changed_at!
    Apply::Operation::Engine::Broadcast.call(apply: model)
    notice(I18n.t("apply.mark_outcome.success.#{outcome}"))
  end

  private

  def reject!(message)
    add_error(:base, message)
    raise ActiveRecord::RecordInvalid
  end
end
