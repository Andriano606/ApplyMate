# frozen_string_literal: true

# Publishes the token user's feedback, or replaces it when they already have one
# (one per user). Wraps Feedback::Operation::{Create,Update} so the web form and
# Claude share the same rules; validation errors come back as one readable message.
class Mcp::Operation::SubmitFeedback < ApplyMate::Operation::Base
  def perform!(params:, current_user:, **)
    existing = Feedback.find_by(user: current_user) # a fresh read, not the cached has_one
    authorize! existing || Feedback.new(user: current_user), existing ? :update? : :create?

    attributes = { feedback: { rating: params[:rating], body: params[:comment] } }
    sub_result = if existing
                   run_operation(Feedback::Operation::Update, { params: attributes.merge(id: existing.to_param), current_user:,
                                                                posted_via: 'mcp', manually_handle_errors: true })
    else
                   run_operation(Feedback::Operation::Create, { params: attributes, current_user:,
                                                                posted_via: 'mcp', manually_handle_errors: true })
    end

    if sub_result.failure?
      add_error(:invalid, sub_result.model.errors.full_messages.join('. '))
      raise ActiveRecord::RecordInvalid
    end

    self.model = ApplyMate::Operation::Struct.new(feedback: sub_result.model, created: existing.nil?)
  end
end
