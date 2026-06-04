# frozen_string_literal: true

module UserHandling
  def current_user
    @current_user ||= user_from_token || user_from_session
  end

  def signed_in?
    current_user.present?
  end

  def impersonating?
    session[:admin_id].present?
  end

  private

  def user_from_session
    User.with_attached_avatar.find_by(id: session[:user_id]) if session[:user_id]
  end

  def user_from_token
    return unless (token = bearer_token)

    api_token = ApiToken.find_by(token:)
    api_token&.touch_used!
    api_token&.user
  end

  def bearer_token
    request.authorization&.match(/\ABearer (.+)\z/)&.captures&.first
  end
end
