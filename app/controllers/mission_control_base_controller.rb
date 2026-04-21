# frozen_string_literal: true

class MissionControlBaseController < ActionController::Base
  include UserHandling

  protect_from_forgery with: :exception
  before_action :require_admin

  private

  def require_admin
    return if current_user&.admin?

    redirect_to main_app.root_path, alert: I18n.t('admin.unauthorized')
  end
end
