# frozen_string_literal: true

class ApplyMate::Component::Link < ApplyMate::Component::Base
  VARIANTS = ApplyMate::Component::Button::VARIANTS
  SIZES = ApplyMate::Component::Button::SIZES

  def initialize(url:, label: nil, icon: nil, variant: :secondary, size: :md, **options)
    @url = url
    @label = label
    @icon_name = icon
    @size = size
    raise ArgumentError, "Unknown variant: #{variant}. Valid variants: #{VARIANTS.keys.join(', ')}" unless VARIANTS.key?(variant)

    @variant = variant
    @options = options
    super()
  end

  def button_classes
    [ VARIANTS[@variant], SIZES[@size] ].join(' ')
  end

  def render_tag
    extra_class = @options[:class]
    merged_class = [ button_classes, extra_class ].compact.join(' ')
    rest_opts = @options.except(:class)

    helpers.link_to(@url, class: merged_class, **rest_opts) { inner_content }
  end

  private

  def inner_content
    if content?
      content
    elsif @icon_name
      icon(@icon_name)
    elsif @label
      @label.to_s.html_safe
    end
  end
end
