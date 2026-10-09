# frozen_string_literal: true

class Apply::Operation::Index < ApplyMate::Operation::Base
  FILTERS = %w[attention].freeze

  def perform!(params:, current_user:, **)
    applies = policy_scope(Apply).includes(:vacancy, :user_profile, :ai_integration)
    authorize! applies, :index?
    filter = FILTERS.find { |name| name == params[:filter].to_s }
    # Rides index_applies_on_user_state; a user's own applies are few, so the created_at sort is cheap.
    applies = applies.public_send(filter) if filter
    self.model = ApplyMate::Operation::Struct.new(
      applies: applies.order(created_at: :desc).paginate(page: params[:page]),
      filter:,
      attention_count: Apply.attention_count_for(current_user)
    )
  end
end
