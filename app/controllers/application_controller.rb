# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include Pundit::Authorization
  include OperationsMethods
  include UserHandling

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Dev convenience: when DEFAULT_LOGIN_EMAIL is set, start already signed in as
  # that user so each Conductor workspace skips the login flow. Registered only
  # in development — never bypasses auth in test or production.
  before_action :auto_login_default_user if Rails.env.development?

  private

  def auto_login_default_user
    email = ENV['DEFAULT_LOGIN_EMAIL'].presence
    return unless email
    return if signed_in? # already signed in as a real user (ignores stale session ids)

    user = User.find_by(email:)
    session[:user_id] = user.id if user
  end

  def append_info_to_payload(payload)
    super
    payload[:request_id] = request.request_id
    payload[:user_id]    = current_user&.id
  end
end
