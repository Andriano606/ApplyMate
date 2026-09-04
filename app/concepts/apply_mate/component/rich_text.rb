# frozen_string_literal: true

# Renders scraped HTML (a vacancy's `description_html`) as readable prose.
#
# The scraper stores the source's own markup verbatim, so this is the single place
# that decides which tags survive and how they look. Sanitising here — at render,
# not at write — keeps the stored copy faithful while still rendering nothing the
# allow-list doesn't cover.
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

  def initialize(html:)
    @html = html
  end

  def render?
    @html.present?
  end

  private

  # Sanitising last keeps the return value a SafeBuffer, so nothing here needs
  # `html_safe` — the allow-list is still the final word on what reaches the page.
  def safe_html
    helpers.sanitize(compacted_html, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
  end

  # Djinni pads its descriptions with empty `<p> </p>` spacers. They hold no text
  # but each still takes a full block gap, which tears ragged holes between the
  # sections. Drop them here rather than at scrape time: the stored markup stays
  # exactly what the employer wrote.
  def compacted_html
    fragment = Nokogiri::HTML::DocumentFragment.parse(@html.to_s)
    fragment.css('p, div').each { |node| node.remove if node.text.blank? }
    fragment.to_html
  end
end
