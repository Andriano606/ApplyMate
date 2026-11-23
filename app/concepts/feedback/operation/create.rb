# frozen_string_literal: true

# Posts the user's (only) feedback. `posted_via:` is set by trusted callers
# (Mcp::Operation::SubmitFeedback passes 'mcp'), never read from params.
class Feedback::Operation::Create < ApplyMate::Operation::Base
  def perform!(params:, current_user:, posted_via: 'web', **)
    self.model = Feedback.new(user: current_user, posted_via:)
    authorize! model, :create?

    model.assign_attributes(rating: params.dig(:feedback, :rating), body: params.dig(:feedback, :body))
    save_once!
    notice(I18n.t('feedback.create.success'))
  end

  private

  # Two concurrent first posts (double submit, parallel MCP calls) both pass the
  # validation; the unique index on user_id rejects the second one.
  def save_once!
    model.save!
  rescue ActiveRecord::RecordNotUnique
    model.errors.add(:base, I18n.t('feedback.errors.already_exists'))
    raise ActiveRecord::RecordInvalid, model
  end
end
