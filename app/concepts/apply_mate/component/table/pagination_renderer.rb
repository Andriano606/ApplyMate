# frozen_string_literal: true

# Renders two variants of the same pagination: a compact one for phones
# (arrows, first/current/last page) and the full windowed one from `lg` up.
# The full list with "« Попередня / Наступна »" is up to ~900px wide: on phones and
# tablets it wraps into a ragged second row.
class ApplyMate::Component::Table::PaginationRenderer < WillPaginate::ActionView::LinkRenderer
  ITEM = 'inline-flex items-center justify-center rounded-lg text-sm font-medium'
  LINK = "#{ITEM} text-gray-700 dark:text-gray-300 bg-white dark:bg-gray-800 border border-gray-300 " \
         'dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors'
  CURRENT = "#{ITEM} text-white bg-blue-600 border border-blue-600".freeze
  DISABLED = "#{ITEM} text-gray-400 dark:text-gray-500 bg-gray-100 dark:bg-gray-900 border border-gray-200 " \
             'dark:border-gray-700 cursor-not-allowed'
  MOBILE_SIZE = 'min-w-9 h-9 px-2'
  DESKTOP_SIZE = 'px-3 py-2'

  def to_html
    html_container(mobile_html + desktop_html)
  end

  def container_attributes
    { class: 'flex items-center justify-center', 'aria-label': @template.will_paginate_translate(:container_aria_label) { 'Pagination' } }
  end

  protected

  def html_container(html)
    tag(:nav, html, container_attributes)
  end

  private

  def mobile_html
    items = mobile_page_numbers.map { |item| item == :gap ? gap_tag('px-1') : page_tag(item, MOBILE_SIZE) }
    items.unshift(arrow_tag(previous_page_number, '&lsaquo;', :previous_aria_label, 'Previous page'))
    items.push(arrow_tag(next_page_number, '&rsaquo;', :next_aria_label, 'Next page'))
    tag(:div, items.join, class: 'flex items-center gap-1 lg:hidden')
  end

  def desktop_html
    items = windowed_page_numbers.map { |item| item == :gap ? gap_tag('px-2') : page_tag(item, DESKTOP_SIZE) }
    items.unshift(step_tag(previous_page_number, @options[:previous_label], DESKTOP_SIZE))
    items.push(step_tag(next_page_number, @options[:next_label], DESKTOP_SIZE))
    tag(:div, items.join, class: 'hidden lg:flex lg:flex-wrap items-center justify-center gap-1')
  end

  # First, current and last page; a gap that would hide a single page shows
  # that page instead, so "1 … 3" never happens.
  def mobile_page_numbers
    pages = [ 1, current_page.to_i, total_pages ].uniq
    pages.each_cons(2).flat_map do |from, to|
      case to - from
      when 1 then [ from ]
      when 2 then [ from, from + 1 ]
      else [ from, :gap ]
      end
    end + [ pages.last ]
  end

  def previous_page_number
    current_page - 1 if current_page > 1
  end

  def next_page_number
    current_page + 1 if current_page < total_pages
  end

  def page_tag(page, size)
    aria_label = @template.will_paginate_translate(:page_aria_label, page:) { "Page #{page}" }
    if page == current_page
      tag(:span, page, class: "#{CURRENT} #{size}", 'aria-current': 'page', 'aria-label': aria_label)
    else
      link(page, page, class: "#{LINK} #{size}", 'aria-label': aria_label)
    end
  end

  def arrow_tag(page, text, aria_key, aria_default)
    aria_label = @template.will_paginate_translate(aria_key) { aria_default }
    step_tag(page, text, "#{MOBILE_SIZE} text-lg", 'aria-label': aria_label)
  end

  def step_tag(page, text, size, **attributes)
    if page
      link(text, page, class: "#{LINK} #{size}", **attributes)
    else
      tag(:span, text, class: "#{DISABLED} #{size}", **attributes)
    end
  end

  def gap_tag(padding)
    tag(:span, '&hellip;', class: "#{padding} text-gray-500 dark:text-gray-400")
  end
end
