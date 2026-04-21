# frozen_string_literal: true

class ApplyMate::Component::DebugButton < ApplyMate::Component::Base
  available_for :admin

  def initialize(path:, text:, **options)
    @path = path
    @text = text
    @options = options
  end

  def button_classes
    'inline-flex items-center px-4 py-2 text-sm font-medium text-white ' \
      'bg-purple-600 rounded-lg hover:bg-purple-700 transition-colors'
  end
end
