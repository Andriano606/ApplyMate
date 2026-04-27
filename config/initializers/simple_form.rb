# frozen_string_literal: true

SimpleForm.setup do |config|
  # Tailwind CSS wrapper
  config.wrappers :default, class: 'mb-4' do |b|
    b.use :html5
    b.use :placeholder
    b.optional :maxlength
    b.optional :minlength
    b.optional :pattern
    b.optional :min_max
    b.optional :readonly

    b.use :label, class: 'block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1'
    b.use :input,
         class: 'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg ' \
                'bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 ' \
                'focus:ring-2 focus:ring-blue-500 focus:border-blue-500 transition-colors',
         error_class: 'border-red-500 focus:ring-red-500 focus:border-red-500'
    b.use :hint, wrap_with: { tag: :p, class: 'mt-1 text-sm text-gray-500 dark:text-gray-400' }
    b.use :error, wrap_with: { tag: :p, class: 'mt-1 text-sm text-red-600' }
  end

  # Checkbox wrapper
  config.wrappers :checkbox, class: 'flex items-center mb-4' do |b|
    b.use :html5
    b.use :input, class: 'h-4 w-4 text-blue-600 border-gray-300 dark:border-gray-600 rounded focus:ring-blue-500'
    b.use :label, class: 'ml-2 block text-sm text-gray-700 dark:text-gray-300'
    b.use :error, wrap_with: { tag: :p, class: 'mt-1 text-sm text-red-600' }
  end

  # Select wrapper
  config.wrappers :select, class: 'mb-4' do |b|
    b.use :html5
    b.use :placeholder
    b.use :label, class: 'block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1'
    b.use :input,
         class: 'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg ' \
                'focus:ring-2 focus:ring-blue-500 focus:border-blue-500 ' \
                'bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 transition-colors',
         error_class: 'border-red-500'
    b.use :hint, wrap_with: { tag: :p, class: 'mt-1 text-sm text-gray-500 dark:text-gray-400' }
    b.use :error, wrap_with: { tag: :p, class: 'mt-1 text-sm text-red-600' }
  end

  # Wrapper with no default input classes — consumer supplies all styling via input_html
  config.wrappers :plain do |b|
    b.use :html5
    b.use :placeholder
    b.optional :min_max
    b.optional :readonly
    b.use :input
    b.use :error, wrap_with: { tag: :p, class: 'mt-1 text-sm text-red-600' }
  end

  config.default_wrapper = :default
  config.boolean_style = :inline
  config.button_class = 'bg-blue-600 text-white px-4 py-2 rounded-lg hover:bg-blue-700 ' \
                        'transition-colors cursor-pointer disabled:opacity-50'
  config.error_notification_tag = :div
  config.error_notification_class = 'bg-red-50 dark:bg-red-900/30 border border-red-400 text-red-700 dark:text-red-400 px-4 py-3 rounded-lg mb-4'
  config.browser_validations = false
  config.boolean_label_class = 'checkbox'
  config.label_text = ->(label, _required, _explicit_label) { label.to_s }

  # Map input types to wrappers
  config.wrapper_mappings = {
    boolean: :checkbox,
    select: :select,
    collection_select: :select
  }
end

module SimpleForm::WithNewLink
  def initialize(*args)
    super
    new_options = options.delete(:with_new_link)
    return if new_options.blank?

    new_link = new_options.delete(:link)
    return if new_link.nil?

    doc = Nokogiri::HTML::DocumentFragment.parse(new_link)
    uri = URI.parse(doc.at('a')['href'])
    params = Rack::Utils.parse_query(uri.query)
    target = input_html_options[:id] || @builder.field_id(attribute_name)

    # While the turbo_callback string is safe to expose to the users we sign the string to avoid leaking internal
    # components/logic to the users.
    # The turbo_callback string is decoded in app/controllers/concerns/turbo_callback.rb when the callback is executed.
    verifier = ActiveSupport::MessageVerifier.new(Rails.application.credentials.secret_key_base)
    callback_options = verifier.generate(new_options)
    params['turbo_callback'] = [ :select_option, target, callback_options ].compact.join(':')

    uri.query = params.to_query
    doc.at('a')['href'] = uri.to_s

    existing_hint = options[:hint]
    options[:hint] = [ existing_hint, doc.to_html ].compact.join(' ').html_safe # rubocop:disable Rails/OutputSafety
  end
end
SimpleForm::Inputs::CollectionSelectInput.prepend SimpleForm::WithNewLink
