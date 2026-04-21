# frozen_string_literal: true

class ApplyMate::Component::Alert < ApplyMate::Component::Base
  STYLES = {
    notice: { container: 'bg-green-50 border border-green-200', icon_color: 'text-green-600', text: 'text-green-800', icon_name: :check_circle },
    info:   { container: 'bg-blue-50 border border-blue-200',   icon_color: 'text-blue-600',  text: 'text-blue-800',  icon_name: :info_circle },
    error:  { container: 'bg-red-50 border border-red-200',     icon_color: 'text-red-600',   text: 'text-red-800',   icon_name: :x_circle }
  }.freeze

  def initialize(text:, type: :error)
    @text = text
    @type = type.to_sym
  end

  private

  attr_reader :text, :type

  def style
    STYLES[type] || STYLES[:error]
  end
end
