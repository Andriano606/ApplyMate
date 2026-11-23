class FeedbacksController < ApplicationController
  # create/update use the endpoint default: flash + turbo refresh (morph) of the feedback page.
  def index
    endpoint Feedback::Operation::Index, Feedback::Component::Index
  end

  def new
    endpoint Feedback::Operation::New, Feedback::Component::FormModal
  end

  def create
    endpoint Feedback::Operation::Create, Feedback::Component::FormModal
  end

  def edit
    endpoint Feedback::Operation::Edit, Feedback::Component::FormModal
  end

  def update
    endpoint Feedback::Operation::Update, Feedback::Component::FormModal
  end

  # Same as create/update: flash + morph refresh (the page also changes its
  # summary and, for the author, swaps the card for the "leave feedback" call).
  def destroy
    endpoint Feedback::Operation::Destroy do |m|
      m.success do |result|
        flash[result.message_level] = result.notice[:text]
        render turbo_stream: turbo_stream.action(:refresh, nil, method: :morph)
      end
    end
  end
end
