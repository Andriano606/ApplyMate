# frozen_string_literal: true

class ApplyMate::Component::ExpandableText < ApplyMate::Component::Base
  CLAMP_CLASSES = {
    1 => 'line-clamp-1',
    2 => 'line-clamp-2',
    3 => 'line-clamp-3',
    4 => 'line-clamp-4',
    5 => 'line-clamp-5',
    6 => 'line-clamp-6'
  }.freeze

  ALLOWED_TAGS       = %w[p br ul ol li strong em b i h1 h2 h3 h4 h5 h6 a].freeze
  ALLOWED_ATTRIBUTES = %w[href].freeze

  def initialize(html:, lines: 3)
    @html  = html
    @lines = lines
  end

  private

  def preview_text
    helpers.strip_tags(@html.to_s)
  end

  def full_html
    helpers.sanitize(@html.to_s, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
  end

  def clamp_class
    CLAMP_CLASSES.fetch(@lines, 'line-clamp-3')
  end
end
