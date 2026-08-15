# frozen_string_literal: true

# Closes the loop after the person submitted the application themselves, from
# their own browser. Nothing to verify from our side — we were never on that
# page — so this records what the user reports and stops the apply from sitting
# in needs_review forever.
class Apply::Operation::ConfirmManualSubmit < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    apply = Apply.find_by_hashid!(params[:id])
    authorize! apply, :retry?
    self.model = apply

    apply.update!(status: :completed, error: nil, review_fields: nil)
    Apply::TurboHandler::StatusUpdate.broadcast(apply)

    notice(I18n.t('apply.manual.confirmed'))
  end
end
