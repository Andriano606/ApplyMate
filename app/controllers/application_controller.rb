# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include Pundit::Authorization
  include OperationsMethods
  include UserHandling

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  private

  def append_info_to_payload(payload)
    super
    payload[:request_id] = request.request_id
    payload[:user_id]    = current_user&.id
  end
end
