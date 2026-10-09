# frozen_string_literal: true

# The user approves the answers of a needs_review apply, optionally with edits (design §8.2). One state-guarded
# UPDATE: needs_review -> queued, with the final answers, their digest (the approval is bound to exactly these
# answers: ReviewRequired compares it), reviewed_at and, when the user confirmed it, duplicate_confirmed_at. 0 rows
# means a concurrent cancel / expiry won: the user gets not_allowed.
#
# params[:answers]  { field_id => value } the edited fields only; ids that are not fields of the apply are ignored,
#                   each value is checked like an AI answer (Answer::CoerceValue). An edit becomes source 'user', and
#                   so does every policy_pending answer (approving it is the consent).
# params[:confirm_duplicate]  required to go on when the review was opened by already_applied.
class Apply::Operation::ApproveReview < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    self.model = policy_scope(Apply).includes(:vacancy).find(params[:id])
    authorize! model, :approve_review?

    confirm = ActiveModel::Type::Boolean.new.cast(params[:confirm_duplicate]) || false
    refuse!(I18n.t('apply.approve_review.duplicate_confirmation_required')) if duplicate_unconfirmed?(confirm)

    answers = final_answers(edits(params))
    approve!(answers, confirm)

    Apply::Operation::Engine::Enqueue.call(apply: model)
    model.touch_user_applies_changed_at!
    Apply::Operation::Engine::Broadcast.call(apply: model)
    notice(I18n.t('apply.approve_review.success'))
  end

  private

  def edits(params)
    raw = params[:answers]
    raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
    # File fields are never edited here (the form shows the CV name only; a posted string would become an upload
    # path). A multiple select posts a blank sentinel, so [""] is "cleared" (nil), not an unknown option.
    fields = model.field_list.reject(&:file?).index_by(&:id)
    raw.to_h.stringify_keys.slice(*fields.keys).to_h do |id, value|
      [ id, coerced(fields.fetch(id), value.is_a?(Array) ? value.compact_blank : value) ]
    end
  end

  def coerced(field, value)
    outcome = Apply::Operation::Answer::CoerceValue.call(field:, value:)
    invalid!(field) if outcome[:error]
    outcome.model
  end

  def final_answers(edited)
    answers = (model.answers || {}).deep_dup
    answers.each_value { |answer| answer['source'] = 'user' if answer['source'] == 'policy_pending' }
    edited.each { |id, value| answers[id] = { 'value' => value, 'source' => 'user', 'confidence' => 1.0 } }
    require_filled!(answers)
    answers
  end

  # A required field the user's consent left blank (no affirmative option) must be filled in before approving.
  def require_filled!(answers)
    model.field_list.select(&:required).each do |field|
      answer = answers[field.id]
      invalid!(field) if answer && answer['source'] == 'user' && answer['value'].blank? && answer['value'] != 0
    end
  end

  def approve!(answers, confirm)
    now = Time.current
    updated = Apply.where(id: model.id, state: Apply.states.fetch(:needs_review)).update_all(
      answers:, answers_approved_digest: Apply::Operation::Answer::Digest.call(answers:).model, reviewed_at: now,
      duplicate_confirmed_at: confirm ? now : model.duplicate_confirmed_at,
      state: Apply.states.fetch(:queued), stage: nil, failure: nil, updated_at: now
    )
    refuse!(I18n.t('apply.approve_review.not_allowed')) if updated.zero?
  end

  def duplicate_unconfirmed?(confirm)
    model.failure_code == 'already_applied' && model.duplicate_confirmed_at.nil? && !confirm
  end

  def invalid!(field)
    refuse!(I18n.t('apply.approve_review.invalid_answer', label: field.label.presence || field.id))
  end

  def refuse!(message)
    add_error(:base, message)
    raise ActiveRecord::RecordInvalid
  end
end
