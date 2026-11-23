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
end
