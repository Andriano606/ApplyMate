# frozen_string_literal: true

module TurboCallback
  include Turbo::Streams::ActionHelper

  # We need to filter out GET requests because the callback parameter is sent on every request untill the last
  # POST/PUT/PATCH request. If you need to make the callback work with GET requests as well, you need to make sure that
  # the existing callbacks work. One example the new bank account in company settings -> salary.
  def turbo_callback_request?
    @controller.request.method != 'GET' && @controller.params[:turbo_callback].present?
  end

  def turbo_callback(model:)
    callback, target, options = @controller.params[:turbo_callback].split(':')
    if options
      # The options string is signed in 'SimpleForm::WithNewLink', see that module for more information.
      verifier = ActiveSupport::MessageVerifier.new(Rails.application.credentials.secret_key_base)
      options = verifier.verify(options)
    end

    actions = []
    case callback
    in 'select_option'
      model_name = concept_underscored_class_name(options['option_component'].constantize)
      component = options['option_component'].constantize.new(model_name.to_sym => model)
      actions << @controller.send(:turbo_stream).close_active_modal
      actions << @controller.send(:turbo_stream).select_option(target, component:)
    end

    @controller.render turbo_stream: actions
  end

  private

  def parse_method_chain(chain:, model:)
    chain.split('.').reduce(model) { |model, method| model.public_send(method) }
  end
end
