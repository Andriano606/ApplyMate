# frozen_string_literal: true

# Turns a failed/needs_review apply into training data and a fresh attempt: the
# user's answers go into their AnswerBank (source: manual — overrides anything
# AI-generated), the apply resets and the whole pipeline re-runs. The bank now
# answers the previously open questions deterministically.
class Apply::Operation::RetryWithAnswers < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    apply = Apply.find_by_hashid!(params[:id])
    authorize! apply, :retry?

    save_answers(apply, params[:answers].presence || {})

    apply.update!(status: :checking_applyble, error: nil, review_fields: nil)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)
    Apply::Job::Apply.perform_later(apply.id)

    self.model = apply
    notice(I18n.t('apply.retry.enqueued'))
  end

  private

  def save_answers(apply, answers)
    fields = Array(apply.review_fields).map { |f| f.to_h.stringify_keys }
    bank   = apply.user_profile.answer_banks

    answers.each do |fingerprint, value|
      next if value.blank?

      field = fields.find { |f| f['fingerprint'] == fingerprint }
      next if field.nil?

      upsert_manual(bank, field, value.to_s)
    end
  end

  def upsert_manual(bank, field, value)
    role = field['role'].to_s

    if role.present? && role != 'custom_question'
      entry = bank.find_or_initialize_by(role:)
    else
      question = AnswerBank.normalize_question(
        field['accessible_name'].presence || field['label'].presence || field['name']
      )
      return if question.blank?

      entry = bank.find_or_initialize_by(role: 'custom_question', question:)
    end

    entry.answer = value
    entry.source = :manual
    entry.save!
  end
end
