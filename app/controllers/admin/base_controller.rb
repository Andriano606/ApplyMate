# frozen_string_literal: true

class Admin::BaseController < ApplicationController
  # before_action :require_admin
  #
  # private
  #
  # def require_admin
  #   return if current_user&.admin?
  #
  #   redirect_to root_path, alert: I18n.t('admin.unauthorized')
  # end
end
