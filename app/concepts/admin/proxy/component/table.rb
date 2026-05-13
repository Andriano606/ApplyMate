# frozen_string_literal: true

class Admin::Proxy::Component::Table < ApplyMate::Component::Base
  available_for :admin

  def initialize(proxies:, **)
    @proxies = proxies
  end

  def call
    table = ApplyMate::Component::Table.new(rows: @proxies, empty_message: I18n.t('admin.proxy.index.empty'))

    table.add_column(header: I18n.t('admin.proxy.index.table.url')) do |proxy|
      helpers.content_tag(:span, proxy.url, class: 'font-mono text-sm')
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.success_count')) do |proxy|
      css = proxy.success_count.to_i > 0 ? 'text-green-600 font-medium' : 'text-gray-400'
      helpers.content_tag(:span, proxy.success_count.to_i, class: css)
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.fail_count')) do |proxy|
      css = case proxy.fail_count
      when 0     then 'text-green-600'
      when 1..9  then 'text-yellow-600'
      else            'text-red-600 font-medium'
      end
      helpers.content_tag(:span, proxy.fail_count, class: css)
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.ratio')) do |proxy|
      total = proxy.success_count + proxy.fail_count
      ratio = total > 0 ? proxy.success_count.to_f / total : 1.0
      pct   = (ratio * 100).round
      css   = pct >= 75 ? 'text-green-600 font-medium' : (pct >= 40 ? 'text-yellow-600' : 'text-red-600 font-medium')
      helpers.content_tag(:span, "#{pct}%", class: css)
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.failed_at')) do |proxy|
      proxy.failed_at ? helpers.l(proxy.failed_at, format: :short) : '—'
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.created_at')) do |proxy|
      helpers.l(proxy.created_at, format: :short)
    end

    table.add_column(header: I18n.t('admin.proxy.index.table.actions'), type: :actions) do |proxy|
      circle = helpers.content_tag(:span, icon(:eye), class: 'inline-flex items-center justify-center w-8 h-8 rounded-full border border-gray-300 dark:border-gray-600 text-gray-500 dark:text-gray-400 group-hover:border-gray-600 dark:group-hover:border-gray-300 group-hover:text-gray-800 dark:group-hover:text-gray-100 transition-colors')
      helpers.link_to(circle, helpers.admin_proxy_path(proxy), class: 'group', 'data-turbo-stream': true)
    end

    render table
  end
end
