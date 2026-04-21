# frozen_string_literal: true

class ApplyMate::Component::Base < ViewComponent::Base
  include ApplyMate::Component::IconHelper
  include ApplyMate::Component::TableHelper
  include ApplyMate::Component::Helper
  include ApplyMate::Component::AdminMethodsHelper

  private

  def current_user
    view_context.controller.send(:current_user)
  end

  def signed_in?
    view_context.controller.send(:signed_in?)
  end

  def impersonating?
    view_context.controller.send(:impersonating?)
  end
end
