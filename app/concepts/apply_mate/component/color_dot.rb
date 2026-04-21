# frozen_string_literal: true

class ApplyMate::Component::ColorDot < ApplyMate::Component::Base
  SIZES = {
    xs: 'h-3.5 w-3.5',
    sm: 'h-4 w-4',
    md: 'h-5 w-5',
    lg: 'h-8 w-8'
  }.freeze

  ANY_COLOR_GRADIENT = 'conic-gradient(red,orange,yellow,green,blue,violet,red)'

  def initialize(hex: nil, size: :md, ring: 'ring-1 ring-gray-300', extra_class: nil)
    @hex = hex
    @size = size
    @ring = ring
    @extra_class = extra_class
    super()
  end

  def dot_style
    @hex ? "background-color: #{@hex}" : "background: #{ANY_COLOR_GRADIENT}"
  end

  def dot_title
    @hex ? @hex : I18n.t('print_order.show.settings.color_any')
  end

  def dot_classes
    [ 'inline-block', SIZES[@size], 'rounded-full', @ring, @extra_class ].compact.join(' ')
  end
end
