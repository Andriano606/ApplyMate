# frozen_string_literal: true

# The user types the code a running apply is waiting for (Engine::AwaitInput): owner only, one guarded UPDATE that
# stores it only while the apply is running, parked in stage 'awaiting_input' with an open input_request. The run
# polls the column (by its run_token) and consumes it; a code sent at any other time changes nothing.
class Apply::Operation::ProvideInput < ApplyMate::Operation::Base
  MAX_CODE_LENGTH = 32

  def perform!(params:, current_user:, **)
    self.model = policy_scope(Apply).find(params[:id])
    authorize! model, :provide_input?
    code = params[:code].to_s.strip
    invalid!(:code, I18n.t('apply.provide_input.invalid_code')) if code.blank? || code.length > MAX_CODE_LENGTH

    store!(code)
    model.touch_user_applies_changed_at!
    Apply::Operation::Engine::Broadcast.call(apply: model)
    notice(I18n.t('apply.provide_input.success'))
  end

  private

  def store!(code)
    now = Time.current
    updated = Apply.where(id: model.id, state: :running, stage: 'awaiting_input')
                   .where.not(input_request: nil)
                   .update_all(input_response: { 'code' => code, 'at' => now.iso8601 }, updated_at: now)
    invalid!(:base, I18n.t('apply.provide_input.not_allowed')) if updated.zero?
  end

  def invalid!(attribute, message)
    add_error(attribute, message)
    raise ActiveRecord::RecordInvalid
  end
end
