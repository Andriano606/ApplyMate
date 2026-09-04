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

  def initialize(html:, lines: 3)
    @html  = html
    @lines = lines
  end

  private

  # The collapsed teaser is deliberately tag-free: a line clamp counts rendered
  # lines, and block markup would make the first paragraph the whole preview.
  # The expanded body renders through RichText, which owns sanitisation.
  def preview_text
    helpers.strip_tags(@html.to_s)
  end

  def clamp_class
    CLAMP_CLASSES.fetch(@lines, 'line-clamp-3')
  end
end
