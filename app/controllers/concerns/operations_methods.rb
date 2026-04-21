# frozen_string_literal: true

module OperationsMethods
  include ActionView::Helpers::JavaScriptHelper
  extend ActiveSupport::Concern

  protected

  def endpoint(operation, component = nil, &block)
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

      # We use it for select2 search results
      format.json do
        if action_name == 'index'
          collection = if result.model.is_a?(PrintMate::Operation::Struct)
                         key = operation.to_s.split('::').first.underscore.pluralize
                         result.model[key]
          else
                         result.model
          end

          render json: {
            result: collection.map(&:select2_search_result),
            pagination: {
              more: collection.respond_to?(:next_page) && collection.next_page.present?
            }
          }
        elsif action_name.include?('destroy')
          if result.success?
            render json: { message: result.message }, status: :ok
          else
            render json: { error: result.error_message }, status: :unprocessable_entity
          end
        end
      end
    end
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
