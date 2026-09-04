# frozen_string_literal: true

# Renders a scraped description as readable prose.
#
# The scraper stores the source's own markup verbatim, so this is the single place
# that decides which tags survive and how they look. Sanitising here — at render,
# not at write — keeps the stored copy faithful while still rendering nothing the
# allow-list doesn't cover.
#
# `text:` is the plain-text projection of the same description. Rows scraped before
# markup was stored only have that column, so their blank lines are turned back into
# paragraphs and the rest of the pipeline sees one shape either way.
class ApplyMate::Component::RichText < ApplyMate::Component::Base
  ALLOWED_TAGS = %w[
    p br div span
    ul ol li
    strong b em i u s small
    h1 h2 h3 h4 h5 h6
    a blockquote code pre hr
    table thead tbody tr th td
  ].freeze

  # No `src`: scraped markup must not pull remote images (tracking, mixed content).
  ALLOWED_ATTRIBUTES = %w[href title target rel].freeze

  # Removed with their contents before the allow-list runs. `sanitize` unwraps a
  # disallowed tag rather than dropping it, so a stripped `<script>` would leave its
  # source visible as prose. Separate from Scraper::Base::NON_CONTENT_TAGS on purpose:
  # that list decides what gets *stored*, this one what may leak text into a render.
  NON_RENDERABLE_TAGS = %w[script style noscript template].freeze

  def initialize(html: nil, text: nil)
    @html = html
    @text = text
  end

  def render?
    @html.present? || @text.present?
  end

  private

  # Sanitising last keeps the return value a SafeBuffer, so nothing here needs
  # `html_safe` — the allow-list is still the final word on what reaches the page.
  def safe_html
    helpers.sanitize(prepared_html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
  end

  # Djinni pads its descriptions with empty `<p> </p>` spacers. They hold no text
  # but each still takes a full block gap, which tears ragged holes between the
  # sections. Drop them here rather than at scrape time: the stored markup stays
  # exactly what the employer wrote. Non-renderable subtrees go first, so a block
  # left empty by their removal is compacted away too.
  def prepared_html
    fragment = Nokogiri::HTML::DocumentFragment.parse(source_html)
    fragment.css(NON_RENDERABLE_TAGS.join(',')).each(&:remove)
    fragment.css('p, div').each { |node| node.remove if node.text.blank? }
    fragment.to_html
  end

  def source_html
    return @html.to_s if @html.present?

    helpers.simple_format(@text.to_s)
  end
end
