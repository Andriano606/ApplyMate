# frozen_string_literal: true

class ApplyMate::Endpoint::Html < ApplyMate::Endpoint::Base
  include ApplyMate::Base::ConceptNaming

  def initialize(controller:, component: nil)
    @controller = controller

    @default_handling = lambda do |m|
      m.success do |result|
        @controller.flash[result.message_level] = result.notice if result.notice

        if component.nil?
          case @controller.action_name
          when 'create'
            # Create will by default send the user back to the index page
            path = @controller.public_send "#{@controller.controller_name}_path"
            @controller.redirect_to path
          when 'update'
            # Update will by default send the user back to the edit page for the model
            path = @controller.public_send "edit_#{@controller.controller_name.singularize}_path", result.model
            @controller.redirect_to path
          else
            raise "We dont't handle #{@controller.action_name} for HTML by default, " \
                  'please specify a m.success handler'
          end
        else
          model_name = find_model_name(component)
          render(component, result[:model], model_name)
        end
      end
      m.invalid do |result|
        # We need to use .controller_path in order to get the full namespace (e.g. Salary::Employee)
        base_name = @controller.controller_path.singularize.camelize
        class_name = @controller.action_name == 'update' ? 'Edit' : 'New'
        component = "#{base_name}::Component::#{class_name}"
        begin
          component = component.constantize
        rescue NameError => _e
          raise "To handle the invalid case, you should define #{component}, or handle m.invalid in the controller"
        end
        model_name = find_model_name(component)
        render_options = { status: :unprocessable_content }.merge(render_options)
        render(component, result[:model], model_name)
      end
    end
  end

  private

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

    @controller.render(component.new(**view_options))
  end
end
