# frozen_string_literal: true

class AppliesController < ApplicationController
  def index
    endpoint Apply::Operation::Index, Apply::Component::Index
  end

  def show
    endpoint Apply::Operation::Show do |m|
      m.success do |result|
        redirect_to vacancy_path(result.model.vacancy, anchor: Apply::Component::VacancyApplyCard.anchor_id(result.model))
      end
    end
  end

  def new
    endpoint Apply::Operation::New, Apply::Component::NewModal
  end

  def create
    endpoint Apply::Operation::Create, Apply::Component::NewModal do |m|
      m.success do |result|
        turbo_actions = [ send(:turbo_stream).close_active_modal ]
        turbo_actions << send(:turbo_stream).flash([ [ result.message_level, result.notice[:text] ] ])
        render turbo_stream: turbo_actions
      end
    end
  end

  def destroy
    endpoint Apply::Operation::Destroy
  end

  def resume
    endpoint Apply::Operation::Resume do |m|
      handle_user_transition(m)
    end
  end

  def cancel
    endpoint Apply::Operation::Cancel do |m|
      handle_user_transition(m)
    end
  end

  def approve_review
    endpoint Apply::Operation::ApproveReview do |m|
      handle_user_transition(m)
    end
  end

  def mark_outcome
    endpoint Apply::Operation::MarkOutcome do |m|
      handle_user_transition(m)
    end
  end

  def provide_input
    endpoint Apply::Operation::ProvideInput do |m|
      handle_user_transition(m)
    end
  end

  private

  # The cards refresh through the StatusUpdate broadcast the operation triggers; the response only carries the
  # flash. Plain HTML requests fall back to the apply card on the vacancy page.
  def handle_user_transition(matcher)
    matcher.success do |result|
      if request.format.turbo_stream?
        render turbo_stream: [ send(:turbo_stream).flash([ [ result.message_level, result.notice[:text] ] ]) ]
      else
        flash[result.message_level] = result.notice[:text]
        redirect_to apply_path(result.model)
      end
    end
    matcher.invalid do |result|
      message = result.error_message
      if request.format.turbo_stream?
        render turbo_stream: [ send(:turbo_stream).flash([ [ :error, message ] ]) ], status: :unprocessable_content
      else
        flash[:error] = message
        redirect_to apply_path(result.model)
      end
    end
  end
end
