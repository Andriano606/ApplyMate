# frozen_string_literal: true

class Admin::ProxyMateSettingsController < Admin::BaseController
  def show
    endpoint Admin::ProxyMateSetting::Operation::Show, Admin::ProxyMateSetting::Component::Show
  end

  def update
    endpoint Admin::ProxyMateSetting::Operation::Update, Admin::ProxyMateSetting::Component::Show
  end
end
