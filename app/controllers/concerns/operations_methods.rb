# frozen_string_literal: true

module OperationsMethods
  include ActionView::Helpers::JavaScriptHelper
  extend ActiveSupport::Concern

  protected

  def endpoint(operation, component = nil, serializer = nil, &block)
    result = operation.call(params:, current_user:)

    check_authorization_is_called result

    respond_to do |format|
      format.html do
        ApplyMate::Endpoint::Html.new(controller: self, component:).call(result, &block)
      end

      format.turbo_stream do
        ApplyMate::Endpoint::TurboStream.new(controller: self, component:).call(result, &block)
      end

      format.js do
      end

      format.json do
        ApplyMate::Endpoint::Json.new(controller: self, component:, serializer:, operation:).call(result, &block)
      end
    end
  # API clients get a clean 403; HTML keeps its existing behavior (re-raise).
  rescue Pundit::NotAuthorizedError => e
    raise e unless request.format.json?

    ApplyMate::Endpoint::Json.new(controller: self).render_forbidden
  end

  def check_authorization_is_called(result)
    return if result[:pundit]

    raise Pundit::NotAuthorizedError, 'Authorization was not performed in operation'
  end

  def turbo_redirect_to(url, notice: nil, alert: nil, error: nil)
    flash[:notice] = notice if notice
    flash[:alert] = alert if alert
    flash[:error] = error if error
    render turbo_stream: turbo_stream.action(:redirect, url)
  end
end
