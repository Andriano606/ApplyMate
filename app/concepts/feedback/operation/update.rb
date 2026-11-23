# frozen_string_literal: true

# Edits the user's feedback. `posted_via:` records where the latest version came
# from; it is set by trusted callers only (see Create).
class Feedback::Operation::Update < ApplyMate::Operation::Base
  def perform!(params:, current_user:, posted_via: 'web', **)
    self.model = Feedback.find(params[:id])
    authorize! model, :update?

    model.assign_attributes(rating: params.dig(:feedback, :rating), body: params.dig(:feedback, :body), posted_via:)
    model.save!
    notice(I18n.t('feedback.update.success'))
  end
end
