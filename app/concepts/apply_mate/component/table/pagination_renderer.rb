# frozen_string_literal: true

class ApplyMate::Component::Table::PaginationRenderer < WillPaginate::ActionView::LinkRenderer
  def container_attributes
    { class: 'flex items-center justify-center gap-1' }
  end

  def page_number(page)
    if page == current_page
      tag(:span, page, class: 'px-3 py-2 text-sm font-medium text-white bg-blue-600 rounded-lg')
    else
      link(page, page, class: 'px-3 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600 ' \
                               'rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors')
    end
  end

  def previous_or_next_page(page, text, _classname = nil, _aria_label = nil)
    if page
      link(text, page, class: 'px-3 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600 ' \
                               'rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors')
    else
      tag(:span, text, class: 'px-3 py-2 text-sm font-medium text-gray-400 dark:text-gray-500 bg-gray-100 dark:bg-gray-900 border border-gray-200 dark:border-gray-700 ' \
                               'rounded-lg cursor-not-allowed')
    end
  end

  def gap
    tag(:span, '&hellip;', class: 'px-2 py-2 text-gray-500 dark:text-gray-400')
  end

  protected

  def html_container(html)
    tag(:nav, html, container_attributes)
  end
end
