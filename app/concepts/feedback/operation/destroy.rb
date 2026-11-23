# frozen_string_literal: true

# Deletes a feedback with its whole thread: the author's own, or any as an admin
# (moderation). The author can then post a new one.
class Feedback::Operation::Destroy < ApplyMate::Operation::Base
  def perform!(params:, **)
    self.model = Feedback.find(params[:id])
    authorize! model, :destroy?

    model.destroy!
    notice(I18n.t('feedback.destroy.success'))
  end
end
