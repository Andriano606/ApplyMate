# frozen_string_literal: true

class ApplyMate::Endpoint::TurboStream < ApplyMate::Endpoint::Base
  include ApplyMate::Base::ConceptNaming

  def initialize(controller:, component:)
    @controller = controller

    @default_handling = lambda do |m|
      m.success { |result| render_success(result, component) }
      m.invalid { |result| render_invalid(result, component) }
    end
  end

  def render_success(result, component)
    turbo_actions = []
    model_name = find_model_name(component) if component
    frame_id = @controller.send(:turbo_frame_request_id) || 'main-content'

    case @controller.action_name
    when 'create', 'update'
      @controller.flash[result.message_level] = result.notice[:text] if result.notice
      if @controller.request.referer.include?('/new')
        path = @controller.public_send "#{@controller.controller_name}_path"
        turbo_actions << @controller.send(:turbo_stream).action(:redirect, path)
      else
        turbo_actions << @controller.send(:turbo_stream).action(:refresh, nil, method: :morph)
      end
    when 'destroy'
      turbo_actions << @controller.send(:turbo_stream).remove_by_id(result.model.id)
      turbo_actions << @controller.send(:turbo_stream).flash([ [ result.message_level, result.notice[:text] ] ])
    else
      raise 'For all turbo actions you need to define the view_class' if component.nil?

      html = render(component, result.model, model_name)
      if modal?(component)
        frame_id = if result[:model].is_a?(ApplyMate::Operation::Struct) && result[:model]
                     "#{@controller.helpers.dom_id(result[:model][model_name])}_modal"
        elsif result[:model].nil?
                     "#{model_name}_modal"
        else
                     "#{@controller.helpers.dom_id(result.model)}_modal"
        end
        turbo_actions << @controller.send(:turbo_stream).create_element_if_not_exist(target: frame_id, parent_id: 'turbo-modals')
      end
      turbo_actions << @controller.send(:turbo_stream).replace(frame_id, html:, method: :morph)
    end
    @controller.render turbo_stream: turbo_actions
  end

  def render_invalid(result, component)
    turbo_actions = []
    model_name = concept_underscored_class_name(component) if component

    case @controller.action_name
    when 'destroy'
      @controller.flash[:alert] = result.errors.merge!(result.model.errors).map(&:message)
      turbo_actions << @controller.send(:turbo_stream).flash(@controller.flash)
    else
      raise 'For all turbo actions you need to define the component' if component.nil?

      frame_id = @controller.send(:turbo_frame_request_id)
      if modal?(component)
        frame_id ||= if result[:model].is_a?(ApplyMate::Operation::Struct)
          "#{@controller.helpers.dom_id(result[:model][model_name])}_modal"
        else
          "#{@controller.helpers.dom_id(result.model)}_modal"
        end
      end

      frame_id ||= 'main-content'

      html = render(component, result.model, model_name)
      turbo_actions << @controller.send(:turbo_stream).replace(frame_id, html:, method: :morph)
    end

    @controller.render turbo_stream: turbo_actions, status: :unprocessable_content
  end

  def render(component, model, model_name)
    view_options = {}

    if model.is_a?(ApplyMate::Operation::Struct)
      # If this is a ApplyMate struct we decompose it into a hash and pass that as arguments
      view_options = view_options.merge(model.to_h)
    else
      # If not component expects the argument to be the model_name,
      # such as product: for edit/update and products for index
      # Lets add that to the keyword params we pass in:
      view_options[model_name.to_sym] = model
    end

    @controller.render_to_string(component.new(**view_options))
  end

  private

  def modal?(view_class)
    view_class.to_s.demodulize.include?('Modal')
  end
end
