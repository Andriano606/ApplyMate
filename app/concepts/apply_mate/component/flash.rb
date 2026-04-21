# frozen_string_literal: true

class ApplyMate::Component::Flash < ApplyMate::Component::Base
  STYLES = {
    notice:  { container: 'bg-white dark:bg-gray-800 border-l-4 border-green-500', icon_bg: 'bg-green-100',
               icon_color: 'text-green-600', text: 'text-gray-800 dark:text-gray-200', icon_name: :check_circle },
    success: { container: 'bg-white dark:bg-gray-800 border-l-4 border-green-500', icon_bg: 'bg-green-100',
               icon_color: 'text-green-600', text: 'text-gray-800 dark:text-gray-200', icon_name: :check_circle },
    alert:   { container: 'bg-white dark:bg-gray-800 border-l-4 border-red-500', icon_bg: 'bg-red-100',
               icon_color: 'text-red-600', text: 'text-gray-800 dark:text-gray-200', icon_name: :x_circle },
    error:   { container: 'bg-white dark:bg-gray-800 border-l-4 border-red-500', icon_bg: 'bg-red-100',
               icon_color: 'text-red-600', text: 'text-gray-800 dark:text-gray-200', icon_name: :x_circle },
    warning: { container: 'bg-white dark:bg-gray-800 border-l-4 border-yellow-500', icon_bg: 'bg-yellow-100',
               icon_color: 'text-yellow-600', text: 'text-gray-800 dark:text-gray-200', icon_name: :exclamation_triangle },
    info:    { container: 'bg-white dark:bg-gray-800 border-l-4 border-blue-500', icon_bg: 'bg-blue-100',
               icon_color: 'text-blue-600', text: 'text-gray-800 dark:text-gray-200', icon_name: :info_circle }
  }.freeze

  attr_reader :type, :message, :flash_id

  def initialize(type:, message:)
    @type = type.to_sym
    @message = message
    @flash_id = "flash-#{SecureRandom.hex(4)}"
    super()
  end

  def style
    STYLES[type] || STYLES[:info]
  end

  def container_class
    "flex items-center gap-4 p-4 rounded-lg shadow-xl animate-slide-in #{style[:container]}"
  end

  def icon_container_class
    "flex-shrink-0 w-10 h-10 rounded-full flex items-center justify-center #{style[:icon_bg]}"
  end

  def message_class
    "text-sm font-medium #{style[:text]}"
  end

  def flash_icon
    icon(style[:icon_name], class: style[:icon_color])
  end
end
