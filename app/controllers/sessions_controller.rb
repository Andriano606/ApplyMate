# frozen_string_literal: true

class SessionsController < ApplicationController
  def new
    endpoint Session::Operation::New, Session::Component::AuthModal
  end

  def oauth_callback
    params[:auth] = request.env['omniauth.auth']

    endpoint Session::Operation::OauthCallback do |m|
      m.success do |result|
        session[:user_id] = result.model.id
        redirect_to root_path, notice: I18n.t('session.oauth_callback.success')
      end

      m.invalid do
        redirect_to root_path, alert: I18n.t('session.oauth_callback.failure')
      end
    end
  end

  def destroy
    endpoint Session::Operation::Destroy do |m|
      m.success do
        session.delete(:user_id)
        redirect_to root_path, notice: I18n.t('session.destroy.success')
      end
    end
  end

  def failure
    redirect_to root_path, alert: I18n.t('session.failure.message')
  end
end
