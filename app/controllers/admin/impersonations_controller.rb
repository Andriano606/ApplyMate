# frozen_string_literal: true

class Admin::ImpersonationsController < ApplicationController
  before_action :require_admin_access
  before_action :require_not_impersonating, only: :create

  def create
    endpoint Admin::Impersonation::Operation::Create do |m|
      m.success do |result|
        session[:admin_id] = session[:user_id]
        session[:user_id] = result.model.id
        redirect_to root_path, notice: I18n.t('admin.impersonation.create.success')
      end
    end
  end

  def destroy
    admin_user = User.find(session[:admin_id])
    session[:user_id] = admin_user.id
    session.delete(:admin_id)
    redirect_to admin_root_path, notice: I18n.t('admin.impersonation.destroy.success')
  end

  private

  def require_admin_access
    return if current_user&.admin? || impersonating?

    redirect_to root_path, alert: I18n.t('admin.unauthorized')
  end

  def require_not_impersonating
    redirect_to root_path, alert: I18n.t('admin.unauthorized') if impersonating?
  end
end
