# frozen_string_literal: true

module ApplyMate::Component::TableHelper
  extend ActiveSupport::Concern

  def show_table_button(link:)
    circle = helpers.content_tag(:span, icon(:eye), class: 'inline-flex items-center justify-center w-8 h-8 rounded-full border border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400 group-hover:border-gray-600 dark:group-hover:border-gray-300 group-hover:text-gray-800 dark:group-hover:text-gray-100 transition-colors')
    helpers.link_to(circle, link, class: 'group')
  end

  def edit_table_button(link:, turbo_stream: true)
    circle = helpers.content_tag(:span, icon(:edit), class: 'inline-flex items-center justify-center w-8 h-8 rounded-full border border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400 group-hover:border-blue-500 dark:group-hover:border-blue-400 group-hover:text-blue-600 dark:group-hover:text-blue-400 transition-colors')
    helpers.link_to(circle, link, { class: 'group', 'data-turbo-stream': turbo_stream, **data_test_id('edit-button') })
  end

  def delete_table_button(link:, confirm:)
    circle = helpers.content_tag(:span, icon(:trash), class: 'inline-flex items-center justify-center w-8 h-8 rounded-full border border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400 group-hover:border-red-500 dark:group-hover:border-red-400 group-hover:text-red-600 dark:group-hover:text-red-400 transition-colors')
    helpers.link_to(circle, link, class: 'group', 'data-turbo-method': :delete, 'data-turbo-confirm': confirm)
  end

  def post_table_button(link:, icon:, confirm: nil)
    circle = helpers.content_tag(:span, icon(icon), class: 'inline-flex items-center justify-center w-8 h-8 rounded-full border border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400 group-hover:border-green-500 dark:group-hover:border-green-400 group-hover:text-green-600 dark:group-hover:text-green-400 transition-colors')
    options = { class: 'group', 'data-turbo-method': :post }
    options[:'data-turbo-confirm'] = confirm if confirm.present?
    helpers.link_to(circle, link, **options)
  end

  def refresh_table_button(link:)
    circle = helpers.content_tag(:span, icon(:refresh), class: 'inline-flex items-center justify-center w-8 h-8 rounded-full border border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400 group-hover:border-indigo-500 dark:group-hover:border-indigo-400 group-hover:text-indigo-600 dark:group-hover:text-indigo-400 transition-colors')
    helpers.link_to(circle, link, class: 'group', 'data-turbo-method': :patch)
  end
end
