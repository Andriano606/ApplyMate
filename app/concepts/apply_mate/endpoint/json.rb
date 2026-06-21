# frozen_string_literal: true

class ApplyMate::Endpoint::Json < ApplyMate::Endpoint::Base
  def initialize(controller:, component: nil, serializer: nil, operation: nil)
    @controller = controller
    @component = component
    @serializer = serializer
    @operation = operation
  end

  # JSON API (documented via rswag) when a serializer is passed to the endpoint,
  # otherwise the legacy select2 / destroy behavior below.
  def call(result, &)
    if @serializer
      render_serialized(result)
    elsif @controller.action_name == 'index'
      render_index(result)
    elsif @controller.action_name.include?('destroy')
      render_destroy(result)
    end
  end

  def render_forbidden
    @controller.render json: { error: 'forbidden' }, status: :forbidden
  end

  private

  def render_serialized(result)
    @controller.render json: @serializer.call(result.model)
  end

  def render_index(result)
    collection = if result.model.is_a?(ApplyMate::Operation::Struct)
                   key = @operation.to_s.split('::').first.underscore.pluralize
                   result.model[key]
    else
                   result.model
    end

    @controller.render json: {
      result: collection.map(&:select2_search_result),
      pagination: {
        more: collection.respond_to?(:next_page) && collection.next_page.present?
      }
    }
  end

  def render_destroy(result)
    if result.success?
      @controller.render json: { message: result.message }, status: :ok
    else
      @controller.render json: { error: result.error_message }, status: :unprocessable_entity
    end
  end
end
