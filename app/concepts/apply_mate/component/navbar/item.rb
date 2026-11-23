# frozen_string_literal: true

class ApplyMate::Component::Navbar::Item
  attr_reader :label, :path, :section, :icon_name, :method, :turbo, :options

  VALID_SECTIONS = %i[logo nav actions user_menu guest].freeze

  def initialize(label:, path: nil, section:, icon: nil, method: nil, turbo: nil, render: true, divider: false, **options)
    raise ArgumentError, "invalid section: #{section}" unless VALID_SECTIONS.include?(section)

    @label = label
    @path = path
    @section = section
    @icon_name = icon
    @method = method
    @turbo = turbo
    @render_condition = render
    @divider = divider
    @options = options
  end

  def render?       = @render_condition
  def form_item?    = method.present?
  def turbo_stream? = turbo == :stream
  def divider?      = @divider
  def icon?         = icon_name.present?
  def variant       = options.fetch(:variant, :primary)
  def badge         = options[:badge]
  def badge_count   = options[:badge_count]

  # prefetch: false keeps Turbo from loading the page on hover (a GET with side effects).
  def link_data
    { turbo_stream: (true if turbo_stream?), turbo_prefetch: (false if options[:prefetch] == false) }.compact
  end
end
