# frozen_string_literal: true

class ApplyMate::Component::Navbar::Item
  attr_reader :label, :path, :section, :icon_name, :method, :turbo, :badge, :options

  VALID_SECTIONS = %i[logo nav actions user_menu guest].freeze

  def initialize(label:, path: nil, section:, icon: nil, method: nil, turbo: nil, render: true, divider: false, badge: nil, **options)
    raise ArgumentError, "invalid section: #{section}" unless VALID_SECTIONS.include?(section)

    @label = label
    @path = path
    @section = section
    @icon_name = icon
    @method = method
    @turbo = turbo
    @render_condition = render
    @divider = divider
    @badge = badge
    @options = options
  end

  def render?       = @render_condition
  def form_item?    = method.present?
  def turbo_stream? = turbo == :stream
  def divider?      = @divider
  def icon?         = icon_name.present?
  def badge?        = badge.to_i.positive?
end
