# frozen_string_literal: true

module UserHandling
  def current_user
    @current_user ||= User.with_attached_avatar.find_by(id: session[:user_id]) if session[:user_id]
  end

  def signed_in?
    current_user.present?
  end

  def impersonating?
    session[:admin_id].present?
  end
end
