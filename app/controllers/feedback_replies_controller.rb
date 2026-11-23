class FeedbackRepliesController < ApplicationController
  # Success uses the endpoint default (flash + morph refresh of the feedback
  # page); a failed reply re-renders just its inline form with the error.
  def create
    endpoint FeedbackReply::Operation::Create do |m|
      m.invalid do |result|
        html = render_to_string(FeedbackReply::Component::Form.new(reply: result.model), layout: false)
        render turbo_stream: turbo_stream.replace(FeedbackReply::Component::Form.dom_id_for(result.model.feedback), html:),
               status: :unprocessable_content
      end
    end
  end
end
