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

  # The project has no typography plugin, so the source's own tags each need their
  # spacing and list markers spelled out — otherwise Tailwind's preflight reset
  # renders every paragraph and bullet list as one undifferentiated block.
  PROSE_CLASSES = [
    'text-sm leading-relaxed text-gray-600 dark:text-gray-400 break-words',
    '[&_p]:mb-3 [&_p:last-child]:mb-0',
    '[&_ul]:mb-3 [&_ul]:list-disc [&_ul]:pl-5',
    '[&_ol]:mb-3 [&_ol]:list-decimal [&_ol]:pl-5',
    '[&_li]:mb-1',
    '[&_strong]:font-semibold [&_strong]:text-gray-900 dark:[&_strong]:text-gray-200',
    '[&_b]:font-semibold [&_b]:text-gray-900 dark:[&_b]:text-gray-200',
    '[&_em]:italic [&_i]:italic [&_u]:underline',
    '[&_h1]:mt-4 [&_h2]:mt-4 [&_h3]:mt-4 [&_h4]:mt-4',
    '[&_h1]:mb-2 [&_h2]:mb-2 [&_h3]:mb-2 [&_h4]:mb-2',
    '[&_h1]:text-base [&_h2]:text-base [&_h3]:text-sm [&_h4]:text-sm',
    '[&_h1]:font-semibold [&_h2]:font-semibold [&_h3]:font-semibold [&_h4]:font-semibold',
    '[&_h1]:text-gray-900 [&_h2]:text-gray-900 [&_h3]:text-gray-900 [&_h4]:text-gray-900',
    'dark:[&_h1]:text-gray-200 dark:[&_h2]:text-gray-200 dark:[&_h3]:text-gray-200 dark:[&_h4]:text-gray-200',
    '[&_a]:text-indigo-500 [&_a]:underline hover:[&_a]:text-indigo-700',
    '[&_blockquote]:mb-3 [&_blockquote]:border-l-2 [&_blockquote]:border-gray-200 [&_blockquote]:pl-3 [&_blockquote]:italic',
    'dark:[&_blockquote]:border-gray-700',
    '[&_hr]:my-4 [&_hr]:border-gray-200 dark:[&_hr]:border-gray-700',
    '[&_pre]:mb-3 [&_pre]:whitespace-pre-wrap [&_code]:font-mono [&_code]:text-xs',
    '[&_table]:mb-3 [&_table]:w-full [&_th]:py-1 [&_th]:pr-3 [&_th]:text-left [&_td]:py-1 [&_td]:pr-3'
  ].join(' ').freeze

  def initialize(html:)
    @html = html
  end

  def render?
    @html.present?
  end

  private

  def safe_html
    helpers.sanitize(@html.to_s, tags: ALLOWED_TAGS, attributes: ALLOWED_ATTRIBUTES)
  end
end
